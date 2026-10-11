package com.innocent.media;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * READING A COMMAND'S OUTPUT OVER ADB WITHOUT WAITING FOR THE STREAM TO END.
 *
 * <p>The ADB library (libadb-android 3.1.1) never reports a clean end of a
 * stream. When adbd closes a stream after the command has finished:
 *
 * <ul>
 *   <li>if the reader has already taken every byte and is waiting for more,
 *       the wait ends in {@code IOException("Stream closed.")} — the output
 *       read so far is lost with it;</li>
 *   <li>if some output is still queued, the stream is marked "closing", the
 *       reader takes what is queued, and its next read waits forever: nothing
 *       will ever wake it.</li>
 * </ul>
 *
 * Which one happens is a race between the reader and the library's connection
 * thread. A short command on a slow phone usually loses it harmlessly (the
 * close lands between two reads, and the next read sees end-of-stream), which
 * is why it passed in the lab. A fast phone, or a command whose output comes
 * out over a second or two, loses it the other way: a real Samsung SM-S918B on
 * Android 16 had every Android/data scan end in "Stream closed." about 1.7 s
 * in, the {@code echo ok} probe time out, and the keep-alive and liveness
 * pings report a healthy connection as gone — which then dropped it,
 * reconnected, swept for ports, and looked to the person like ADB that never
 * stays up.
 *
 * <p>So nothing here reads to the end of a stream any more. A text command is
 * sent with an end marker after it — a fresh random token and the command's
 * exit status, on a line of its own — and reading stops at the marker
 * ({@link #untilMarker}). File bytes have a known length, and reading stops at
 * that length ({@link #copyExactly}). Neither ever makes the read the library
 * cannot finish. A stream that closes before its marker is a real failure (the
 * connection dropped, the command was killed), and is reported as one rather
 * than handed back as a short answer.
 */
public final class AdbRead {
    private AdbRead() {}

    private static final SecureRandom RANDOM = new SecureRandom();

    /** No command of ours prints this much; past it something is wrong. */
    static final int MAX_OUTPUT = 64 * 1024 * 1024;

    private static final ScheduledExecutorService WATCH =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "adb-read-watch");
                t.setDaemon(true);
                return t;
            });

    /** A token no file name or command output will contain. */
    public static String newMarker() {
        byte[] b = new byte[8];
        RANDOM.nextBytes(b);
        StringBuilder sb = new StringBuilder("__innocent_end_");
        for (byte x : b) {
            sb.append(Character.forDigit((x >> 4) & 0xf, 16));
            sb.append(Character.forDigit(x & 0xf, 16));
        }
        return sb.append("__").toString();
    }

    /**
     * {@code command}, then the marker and the command's exit status on a line
     * of their own. Newlines rather than {@code ;} so a command ending in a
     * comment or a {@code &&} chain cannot swallow the marker; the status is
     * kept in a variable because the {@code echo} that starts the marker's
     * line would otherwise replace it.
     */
    public static String wrap(String command, String marker) {
        return command + "\n__innocent_rc=$?\necho\necho " + marker + "$__innocent_rc";
    }

    /** What a command printed, and how it exited (-1 if the status was not a number). */
    public static final class Result {
        public final String output;
        public final int exitCode;

        Result(String output, int exitCode) {
            this.output = output;
            this.exitCode = exitCode;
        }
    }

    /**
     * Read {@code in} up to the marker line {@link #wrap} put after the command,
     * and return everything before it — exactly what the command printed.
     *
     * @throws IOException when the stream ends or fails before the marker:
     *     the output is cut short and must not be taken for an answer.
     */
    public static Result untilMarker(InputStream in, String marker) throws IOException {
        byte[] tag = ("\n" + marker).getBytes(StandardCharsets.UTF_8);
        byte[] data = new byte[8 * 1024];
        int len = 0;
        int searchFrom = 0;
        int tagAt = -1;
        byte[] buf = new byte[64 * 1024];
        while (true) {
            if (tagAt < 0) {
                tagAt = indexOf(data, len, tag, searchFrom);
                if (tagAt < 0) searchFrom = Math.max(0, len - tag.length + 1);
            }
            if (tagAt >= 0) {
                int end = indexOf(data, len, new byte[] {'\n'}, tagAt + tag.length);
                if (end >= 0) {
                    String out = new String(data, 0, tagAt, StandardCharsets.UTF_8);
                    String rc = new String(data, tagAt + tag.length, end - tagAt - tag.length,
                            StandardCharsets.US_ASCII).trim();
                    int code;
                    try {
                        code = Integer.parseInt(rc);
                    } catch (NumberFormatException e) {
                        code = -1;
                    }
                    return new Result(out, code);
                }
            }
            int n;
            try {
                n = in.read(buf);
            } catch (IOException e) {
                throw new IOException("output cut off before the command finished ("
                        + e.getMessage() + ")", e);
            }
            if (n < 0) {
                throw new IOException("output cut off before the command finished (stream ended)");
            }
            if (len + n > MAX_OUTPUT) throw new IOException("command output too large");
            if (len + n > data.length) {
                byte[] grown = new byte[Math.max(data.length * 2, len + n)];
                System.arraycopy(data, 0, grown, 0, len);
                data = grown;
            }
            System.arraycopy(buf, 0, data, len, n);
            len += n;
        }
    }

    static int indexOf(byte[] data, int len, byte[] tag, int from) {
        outer:
        for (int i = Math.max(0, from); i + tag.length <= len; i++) {
            for (int j = 0; j < tag.length; j++) {
                if (data[i + j] != tag[j]) continue outer;
            }
            return i;
        }
        return -1;
    }

    /**
     * Copy exactly {@code len} bytes of {@code in} to {@code out}, and stop
     * there: the read after the last byte is the one the library may never
     * finish. Returns how many bytes were copied — fewer than {@code len} when
     * the stream failed, ended early, the receiver went away, or no byte
     * arrived for {@code stallMs} (the wait is interrupted then, so a file that
     * turned out shorter than asked can't hold a thread forever). Time spent
     * writing to {@code out} does not count as a stall: a paused player is
     * allowed to stop reading.
     */
    public static long copyExactly(InputStream in, long len, OutputStream out, long stallMs) {
        if (len <= 0) return 0;
        final Thread reader = Thread.currentThread();
        final Object lock = new Object();
        final long[] readSince = {0L}; // 0 = not inside a read
        ScheduledFuture<?> watch = WATCH.scheduleWithFixedDelay(() -> {
            synchronized (lock) {
                long since = readSince[0];
                if (since != 0L && System.currentTimeMillis() - since > stallMs) {
                    reader.interrupt();
                    readSince[0] = 0L;
                }
            }
        }, Math.max(1L, stallMs / 4), Math.max(1L, stallMs / 4), TimeUnit.MILLISECONDS);
        long written = 0;
        byte[] buf = new byte[256 * 1024];
        try {
            while (written < len) {
                int want = (int) Math.min(buf.length, len - written);
                int n;
                synchronized (lock) {
                    readSince[0] = System.currentTimeMillis();
                }
                try {
                    n = in.read(buf, 0, want);
                } finally {
                    synchronized (lock) {
                        readSince[0] = 0L;
                        // An interrupt that landed as the read returned
                        // anyway must not fail the next one.
                        Thread.interrupted();
                    }
                }
                if (n < 0) break;
                out.write(buf, 0, n);
                written += n;
            }
            out.flush();
        } catch (IOException e) {
            // A short count is the caller's signal; there is nothing more to say.
        } finally {
            watch.cancel(false);
            synchronized (lock) {
                Thread.interrupted();
            }
        }
        return written;
    }
}
