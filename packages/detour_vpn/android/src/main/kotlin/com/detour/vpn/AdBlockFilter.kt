package com.detour.vpn

import android.content.Context
import android.util.Log
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

data class BlockedDomain(val domain: String, val timestampMillis: Long)

/**
 * Intercepts DNS queries at the raw IPv4/UDP packet level, before they'd
 * otherwise be forwarded into the tunnel. A query for a blocked domain never
 * reaches the tunnel or server at all - a synthetic NXDOMAIN reply is written
 * straight back to the TUN device instead.
 *
 * Only handles plain UDP/53 DNS. TCP DNS and DNS-over-HTTPS bypass this
 * entirely - same limitation classic Pi-hole has, not addressed here.
 */
object AdBlockFilter {
    private const val TAG = "AdBlockFilter"
    private const val ASSET_NAME = "adblock_hosts.txt"

    private val blocklist = AtomicReference<Set<String>?>(null)
    val blockedCount = AtomicLong(0)

    // In-memory only (resets with the tunnel session, same as blockedCount) -
    // a bounded ring so a chatty ad domain can't grow this without limit.
    // Never persisted to disk: this is a per-packet hot path, and the
    // VpnLogStore file-rewrite-per-entry pattern used for connection events
    // would be a serious cost here.
    private const val MAX_RECENT = 200
    private val recentBlocks = ArrayDeque<BlockedDomain>(MAX_RECENT)

    private fun ensureLoaded(context: Context): Set<String> {
        blocklist.get()?.let { return it }
        val loaded = try {
            context.assets.open(ASSET_NAME).bufferedReader().useLines { lines ->
                lines.map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }.toHashSet()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load $ASSET_NAME, ad blocking disabled", e)
            emptySet<String>()
        }
        blocklist.compareAndSet(null, loaded)
        return blocklist.get()!!
    }

    private fun isBlocked(context: Context, domain: String): Boolean {
        val set = ensureLoaded(context)
        if (set.isEmpty()) return false
        var d = domain.lowercase().removeSuffix(".")
        while (true) {
            if (set.contains(d)) return true
            val dot = d.indexOf('.')
            if (dot < 0) return false
            d = d.substring(dot + 1)
        }
    }

    /**
     * If [packet] (length [len]) is a DNS query for a blocked domain, returns
     * a synthetic NXDOMAIN response packet ready to write back to the TUN
     * device. Returns null for everything else - non-IPv4, non-UDP, non-DNS,
     * malformed, or not-blocked packets - which the caller should forward
     * through the tunnel unchanged.
     */
    fun tryHandleDns(context: Context, packet: ByteArray, len: Int): ByteArray? {
        try {
            if (len < 28) return null // shorter than min IPv4 + UDP headers
            val versionAndIhl = packet[0].toInt() and 0xFF
            if (versionAndIhl shr 4 != 4) return null // IPv4 only
            val ihl = (versionAndIhl and 0x0F) * 4
            if (ihl < 20 || len < ihl + 8) return null
            val protocol = packet[9].toInt() and 0xFF
            if (protocol != 17) return null // UDP

            val udpOffset = ihl
            val dstPort = readUShort(packet, udpOffset + 2)
            if (dstPort != 53) return null

            val dnsOffset = udpOffset + 8
            if (len < dnsOffset + 12) return null
            val qdCount = readUShort(packet, dnsOffset + 4)
            if (qdCount != 1) return null // only handle the common single-question case

            var pos = dnsOffset + 12
            val nameBuilder = StringBuilder()
            while (pos < len) {
                val labelLen = packet[pos].toInt() and 0xFF
                if (labelLen == 0) {
                    pos += 1
                    break
                }
                if (labelLen and 0xC0 != 0) return null // compression pointer - not expected in a question
                pos += 1
                if (pos + labelLen > len) return null
                if (nameBuilder.isNotEmpty()) nameBuilder.append('.')
                nameBuilder.append(String(packet, pos, labelLen, Charsets.US_ASCII))
                pos += labelLen
            }
            if (pos + 4 > len) return null // qtype + qclass
            val domain = nameBuilder.toString()
            if (domain.isEmpty() || !isBlocked(context, domain)) return null

            blockedCount.incrementAndGet()
            recordBlock(domain)
            return buildNxDomainResponse(packet, len, udpOffset, dnsOffset, ihl)
        } catch (e: Exception) {
            Log.w(TAG, "DNS parse error, forwarding packet unfiltered", e)
            return null
        }
    }

    private fun recordBlock(domain: String) {
        synchronized(recentBlocks) {
            if (recentBlocks.size >= MAX_RECENT) recentBlocks.removeFirst()
            recentBlocks.addLast(BlockedDomain(domain, System.currentTimeMillis()))
        }
    }

    /** Most-recently-blocked first. */
    fun recentDomains(): List<BlockedDomain> {
        synchronized(recentBlocks) { return recentBlocks.toList().asReversed() }
    }

    private fun readUShort(buf: ByteArray, off: Int): Int {
        return ((buf[off].toInt() and 0xFF) shl 8) or (buf[off + 1].toInt() and 0xFF)
    }

    private fun writeUShort(buf: ByteArray, off: Int, value: Int) {
        buf[off] = ((value shr 8) and 0xFF).toByte()
        buf[off + 1] = (value and 0xFF).toByte()
    }

    /** Builds a reply packet in-place from the query: swap addresses/ports, set QR+NXDOMAIN, fix checksums. */
    private fun buildNxDomainResponse(query: ByteArray, len: Int, udpOffset: Int, dnsOffset: Int, ihl: Int): ByteArray {
        val reply = query.copyOf(len)

        // IPv4: swap source/destination addresses.
        for (i in 0 until 4) {
            val tmp = reply[12 + i]
            reply[12 + i] = reply[16 + i]
            reply[16 + i] = tmp
        }

        // UDP: swap source/destination ports.
        for (i in 0 until 2) {
            val tmp = reply[udpOffset + i]
            reply[udpOffset + i] = reply[udpOffset + 2 + i]
            reply[udpOffset + 2 + i] = tmp
        }

        // DNS header flags: QR=1 (response), RD copied from query's RD bit, RA=1, RCODE=3 (NXDOMAIN).
        val queryFlagsLo = reply[dnsOffset + 2].toInt()
        val rd = queryFlagsLo and 0x01
        reply[dnsOffset + 2] = (0x80 or rd).toByte() // QR=1, Opcode=0, AA=0, TC=0, RD=copied
        reply[dnsOffset + 3] = (0x80 or 0x03).toByte() // RA=1, Z=0, RCODE=3 (NXDOMAIN)
        writeUShort(reply, dnsOffset + 6, 0) // ANCOUNT=0
        writeUShort(reply, dnsOffset + 8, 0) // NSCOUNT=0
        writeUShort(reply, dnsOffset + 10, 0) // ARCOUNT=0

        // UDP length + checksum. Checksum is optional over IPv4 (0 = disabled) - simplest correct choice here.
        val udpLength = len - udpOffset
        writeUShort(reply, udpOffset + 4, udpLength)
        writeUShort(reply, udpOffset + 6, 0)

        // IPv4 header checksum (total length unchanged, so only the checksum field needs recomputing).
        reply[10] = 0
        reply[11] = 0
        var sum = 0L
        var i = 0
        while (i < ihl) {
            sum += readUShort(reply, i)
            i += 2
        }
        while (sum shr 16 != 0L) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }
        writeUShort(reply, 10, (sum.inv() and 0xFFFF).toInt())

        return reply
    }
}
