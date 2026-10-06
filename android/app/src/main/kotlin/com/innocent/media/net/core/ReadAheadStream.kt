package com.innocent.media.net

import java.io.IOException
import java.io.InputStream
import java.util.ArrayDeque
import java.util.concurrent.ExecutionException
import java.util.concurrent.Future
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * A file read as [depth] requests kept in flight, [chunk] bytes each.
 *
 * WHY. Over Wi-Fi a request's round trip, not the radio, is what limits one
 * stream: one 1 MiB read at a time waits ~5–20 ms between every megabyte for
 * nothing. Four outstanding reads keep the link busy — the same trick
 * Windows Explorer, VLC's libsmb2 and OpenSSH's sftp (64 requests) use — and
 * it is what lets a 4K remux play from a NAS instead of buffering.
 *
 * [reader] fills the array from the given offset and returns how much it
 * got; fewer than asked means the end of the file.
 */
class ReadAheadStream(
    start: Long,
    private val length: Long,
    private val chunk: Int,
    private val depth: Int,
    private val reader: (ByteArray, Long) -> Int,
) : InputStream() {

    private val pending = ArrayDeque<Future<ByteArray>>()
    private var nextOffset = start
    private var cur: ByteArray = EMPTY
    private var curPos = 0
    private var eof = start >= length
    @Volatile private var closed = false
    private var onClose: (() -> Unit)? = null

    fun onClose(f: () -> Unit): ReadAheadStream {
        onClose = f
        return this
    }

    private fun fill() {
        while (!closed && pending.size < depth && nextOffset < length) {
            val off = nextOffset
            val size = minOf(chunk.toLong(), length - off).toInt()
            nextOffset += size
            pending.addLast(POOL.submit<ByteArray> {
                if (closed) return@submit EMPTY
                val buf = ByteArray(size)
                val n = reader(buf, off)
                if (n == size) buf else buf.copyOf(maxOf(n, 0))
            })
        }
    }

    private fun advance(): Boolean {
        if (closed) throw IOException("closed")
        if (eof) return false
        fill()
        val f = pending.pollFirst() ?: run { eof = true; return false }
        val got = try {
            f.get()
        } catch (e: ExecutionException) {
            val c = e.cause
            throw c as? IOException ?: classify(c ?: e, "read")
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw NetException(NetError.CANCELLED, "read interrupted")
        }
        if (got.isEmpty()) {
            eof = true
            return false
        }
        cur = got
        curPos = 0
        // A short chunk is the real end of the file, whatever length said.
        if (got.size < chunk && nextOffset < length) {
            pending.forEach { it.cancel(true) }
            pending.clear()
            nextOffset = length
        }
        fill()
        return true
    }

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) <= 0) -1 else one[0].toInt() and 0xff
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (curPos >= cur.size && !advance()) return -1
        val n = minOf(len, cur.size - curPos)
        System.arraycopy(cur, curPos, b, off, n)
        curPos += n
        return n
    }

    override fun available(): Int = cur.size - curPos

    override fun close() {
        if (closed) return
        closed = true
        pending.forEach { it.cancel(true) }
        pending.clear()
        onClose?.invoke()
    }

    companion object {
        private val EMPTY = ByteArray(0)
        private val ids = AtomicInteger()

        /** Shared by every open stream; idle threads go after 30 s. */
        val POOL = ThreadPoolExecutor(
            0, 64, 30, TimeUnit.SECONDS, SynchronousQueue(),
            { r -> Thread(r, "net-read-${ids.incrementAndGet()}").apply { isDaemon = true } },
            ThreadPoolExecutor.CallerRunsPolicy(),
        )
    }
}
