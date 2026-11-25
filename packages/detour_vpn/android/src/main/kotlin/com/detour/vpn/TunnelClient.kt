package com.detour.vpn

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * Builds an [SSLContext] that trusts exactly one certificate, identified by
 * its SHA-256 fingerprint - not a CA chain. There's no domain for this
 * server (just a raw IP), so there's nothing for a public CA to vouch for;
 * pinning the server's own self-signed certificate is the whole trust model
 * (same idea as WireGuard pinning a public key, applied to TLS).
 */
private fun buildPinnedSslContext(expectedFingerprintHex: String): SSLContext {
    val trustManager = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}

        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            val cert = chain?.firstOrNull() ?: throw CertificateException("No server certificate presented")
            val digest = MessageDigest.getInstance("SHA-256").digest(cert.encoded)
            val hex = digest.joinToString("") { "%02x".format(it) }
            if (!hex.equals(expectedFingerprintHex, ignoreCase = true)) {
                throw CertificateException("Server certificate fingerprint mismatch: expected $expectedFingerprintHex, got $hex")
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
    }
    return SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustManager), SecureRandom()) }
}

/** The server refused this username and password; retrying can't help. */
class AccessDeniedException : IOException("Access denied: removed by the admin, or wrong password")

class DataLimitException : IOException("Data limit reached, ask the admin for more")

private const val TIMEOUT_MS = 15_000
private const val ADMIN_MARKER = 0

/** Connects and logs in, returning a socket positioned just after an accepted status byte. */
private fun openAuthenticated(config: TunnelConfig, admin: Boolean): SSLSocket {
    val user = config.username.toByteArray(Charsets.UTF_8)
    val pass = config.password.toByteArray(Charsets.UTF_8)
    require(user.size in 1..255 && pass.size <= 255) { "Username or password has an invalid length" }

    val raw = Socket()
    try {
        raw.connect(InetSocketAddress(config.host, config.port), TIMEOUT_MS)
        raw.soTimeout = TIMEOUT_MS
        val s = buildPinnedSslContext(config.fingerprint).socketFactory
            .createSocket(raw, config.host, config.port, true) as SSLSocket
        s.startHandshake()

        val frame = ByteArrayOutputStream()
        if (admin) frame.write(ADMIN_MARKER)
        frame.write(user.size)
        frame.write(user)
        frame.write(pass.size)
        frame.write(pass)
        s.outputStream.write(frame.toByteArray())
        s.outputStream.flush()

        val status = ByteArray(1)
        readFully(s.inputStream, status)
        when (status[0].toInt()) {
            0 -> return s
            1 -> throw AccessDeniedException()
            3 -> throw DataLimitException()
            else -> throw IOException("Server is full")
        }
    } catch (e: Exception) {
        raw.close()
        throw e
    }
}

/** Sends one admin request (JSON) to the server and returns its JSON reply. */
fun sendAdminRequest(config: TunnelConfig, json: String): String =
    openAuthenticated(config, admin = true).use { s ->
        val body = json.toByteArray(Charsets.UTF_8)
        writeFramedPacket(s.outputStream, body, body.size)
        s.inputStream.bufferedReader().readLine() ?: throw IOException("Connection closed")
    }

/** Handles the TLS connect + username/password auth handshake for one session. */
class TunnelClient(private val config: TunnelConfig) {
    var socket: SSLSocket? = null
        private set
    var assignedAddress: String? = null
        private set

    @Throws(Exception::class)
    fun connectAndAuthenticate() {
        val s = openAuthenticated(config, admin = false)
        val ip = ByteArray(4)
        try {
            readFully(s.inputStream, ip)
        } catch (e: Exception) {
            s.close()
            throw e
        }
        assignedAddress = ip.joinToString(".") { it.toUByte().toString() }
        socket = s
    }

    fun close() {
        try {
            socket?.close()
        } catch (_: Exception) {
        }
    }
}

private fun readFully(input: InputStream, buffer: ByteArray) {
    var read = 0
    while (read < buffer.size) {
        val n = input.read(buffer, read, buffer.size - read)
        if (n < 0) throw IOException("Connection closed")
        read += n
    }
}

/** Reads one length-prefixed IP packet frame (2-byte big-endian length). */
fun readFramedPacket(input: InputStream): ByteArray {
    val lenBuf = ByteArray(2)
    readFully(input, lenBuf)
    val len = ((lenBuf[0].toInt() and 0xFF) shl 8) or (lenBuf[1].toInt() and 0xFF)
    val packet = ByteArray(len)
    readFully(input, packet)
    return packet
}

/** Writes one length-prefixed IP packet frame (2-byte big-endian length). */
fun writeFramedPacket(output: OutputStream, packet: ByteArray, length: Int) {
    val header = byteArrayOf(((length shr 8) and 0xFF).toByte(), (length and 0xFF).toByte())
    synchronized(output) {
        output.write(header)
        output.write(packet, 0, length)
        output.flush()
    }
}
