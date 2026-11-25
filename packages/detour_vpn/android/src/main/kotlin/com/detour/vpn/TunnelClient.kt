package com.detour.vpn

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
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

/** Handles the TLS connect + username/password auth handshake for one session. */
class TunnelClient(private val config: TunnelConfig) {
    var socket: SSLSocket? = null
        private set
    var assignedAddress: String? = null
        private set

    @Throws(Exception::class)
    fun connectAndAuthenticate() {
        val factory = buildPinnedSslContext(config.fingerprint).socketFactory
        val s = factory.createSocket(config.host, config.port) as SSLSocket
        s.startHandshake()

        val out = s.outputStream
        val input = s.inputStream

        val userBytes = config.username.toByteArray(Charsets.UTF_8)
        val passBytes = config.password.toByteArray(Charsets.UTF_8)
        val authFrame = ByteArray(1 + userBytes.size + 1 + passBytes.size)
        var offset = 0
        authFrame[offset++] = userBytes.size.toByte()
        userBytes.copyInto(authFrame, offset); offset += userBytes.size
        authFrame[offset++] = passBytes.size.toByte()
        passBytes.copyInto(authFrame, offset)
        out.write(authFrame)
        out.flush()

        val response = ByteArray(5)
        readFully(input, response)
        if (response[0].toInt() != 0) {
            s.close()
            throw IOException("Authentication rejected by server")
        }
        assignedAddress = "${response[1].toUByte()}.${response[2].toUByte()}.${response[3].toUByte()}.${response[4].toUByte()}"
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
