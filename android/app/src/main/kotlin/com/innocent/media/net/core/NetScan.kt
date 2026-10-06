package com.innocent.media.net

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * MX's "Scan": who on this Wi-Fi answers on the protocol's port.
 *
 * Three sources, merged by the caller (NetPlugin):
 *  1. a TCP knock on every address of the phone's /24 — the one method that
 *     finds everything, a Windows PC with discovery off included; ~250
 *     addresses × 48 at a time × 350 ms ≈ 2 s;
 *  2. a NetBIOS node-status query (UDP 137) to each SMB hit, for the name
 *     Windows and Samba answer with ("DESKTOP-7Q2", "NAS");
 *  3. mDNS / DNS-SD (_smb._tcp, _sftp-ssh._tcp, _ftp._tcp) on the Android
 *     side, for Macs, Linux boxes and NASes that announce themselves.
 */
object NetScan {
    data class Hit(val ip: String, val port: Int, val name: String? = null)

    /** Ports per protocol, the standard one first. */
    fun portsFor(p: NetProtocol): IntArray = when (p) {
        NetProtocol.SMB -> intArrayOf(445, 139)
        // 2121 / 2221: the FTP-server apps on Android phones and TV boxes.
        NetProtocol.FTP -> intArrayOf(21, 2121, 2221)
        NetProtocol.FTPS -> intArrayOf(21, 990, 2121)
        NetProtocol.SFTP -> intArrayOf(22, 2222)
    }

    /**
     * The addresses to knock on: the phone's own /24 (a wider network is
     * still scanned only in its /24 — 65 000 knocks is not a scan, it is an
     * attack), without the network, broadcast and own addresses.
     */
    fun neighbours(local: Inet4Address): List<InetAddress> {
        val b = local.address
        val out = ArrayList<InetAddress>(254)
        for (i in 1..254) {
            if (i == (b[3].toInt() and 0xff)) continue
            out.add(InetAddress.getByAddress(byteArrayOf(b[0], b[1], b[2], i.toByte())))
        }
        return out
    }

    fun probe(
        hosts: List<InetAddress>,
        ports: IntArray,
        timeoutMs: Int = 350,
        parallel: Int = 48,
        cancelled: () -> Boolean = { false },
    ): List<Hit> {
        val exec = Executors.newFixedThreadPool(parallel) { r ->
            Thread(r, "net-scan").apply { isDaemon = true }
        }
        try {
            val jobs = hosts.map { h ->
                exec.submit(Callable {
                    for (port in ports) {
                        if (cancelled()) return@Callable null
                        try {
                            Socket().use { s ->
                                s.connect(InetSocketAddress(h, port), timeoutMs)
                                return@Callable Hit(h.hostAddress, port)
                            }
                        } catch (_: Throwable) {
                        }
                    }
                    null
                })
            }
            return jobs.mapNotNull { runCatching { it.get() }.getOrNull() }
        } finally {
            exec.shutdownNow()
            exec.awaitTermination(1, TimeUnit.SECONDS)
        }
    }

    /** A host's NetBIOS name, from a node-status query; null if it is silent. */
    fun netbiosName(ip: InetAddress, timeoutMs: Int = 700): String? = try {
        DatagramSocket().use { s ->
            s.soTimeout = timeoutMs
            val q = nodeStatusQuery()
            s.send(DatagramPacket(q, q.size, ip, 137))
            val buf = ByteArray(1024)
            val p = DatagramPacket(buf, buf.size)
            s.receive(p)
            parseNodeStatus(buf, p.length)
        }
    } catch (_: Throwable) {
        null
    }

    internal fun nodeStatusQuery(): ByteArray {
        val name = ByteArray(16).also { it[0] = '*'.code.toByte() }
        val out = ArrayList<Byte>()
        fun u16(v: Int) { out.add((v shr 8).toByte()); out.add(v.toByte()) }
        u16(0x4e42); u16(0); u16(1); u16(0); u16(0); u16(0)
        out.add(0x20)
        for (b in name) {
            val v = b.toInt() and 0xff
            out.add(('A'.code + (v shr 4)).toByte())
            out.add(('A'.code + (v and 0x0f)).toByte())
        }
        out.add(0)
        u16(0x21); u16(1) // NBSTAT, IN
        return out.toByteArray()
    }

    internal fun parseNodeStatus(b: ByteArray, len: Int): String? {
        var i = 12
        // The echoed question name: labels, or a compression pointer.
        while (i < len) {
            val l = b[i].toInt() and 0xff
            if (l == 0) { i++; break }
            if (l and 0xc0 == 0xc0) { i += 2; break }
            i += 1 + l
        }
        i += 2 + 2 + 4 + 2 // type, class, ttl, rdlength
        if (i >= len) return null
        val count = b[i].toInt() and 0xff
        i++
        var fallback: String? = null
        for (k in 0 until count) {
            if (i + 18 > len) break
            val raw = String(b, i, 15, Charsets.ISO_8859_1).trimEnd(' ', '\u0000')
            val suffix = b[i + 15].toInt() and 0xff
            val group = (b[i + 16].toInt() and 0x80) != 0
            i += 18
            if (group || raw.isEmpty()) continue
            if (suffix == 0x20) return raw // the file-server service
            if (suffix == 0x00 && fallback == null) fallback = raw
        }
        return fallback
    }
}
