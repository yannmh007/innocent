package lab;
import com.innocent.media.AdbRead;
import io.github.muntashirakon.adb.*;
import java.io.*;
import java.security.*;
import java.security.cert.Certificate;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/**
 * The real libadb-android 3.1.1 code, over a real socket, against a fake adbd
 * (FakeAdbd), with the app's own AdbRead. "info" lines show how the old code
 * fared; "PASS"/"FAIL" lines are what the app does now. See README.md.
 */
public class WireLab {
    static PrivateKey KEY; static Certificate CERT;
    static class Mgr extends AbsAdbConnectionManager {
        Mgr() { setApi(36); }
        protected PrivateKey getPrivateKey() { return KEY; }
        protected Certificate getCertificate() { return CERT; }
        protected String getDeviceName() { return "lab"; }
    }
    static int pass = 0, fail = 0;
    static void check(String name, boolean ok, String detail) {
        System.out.printf("%-4s %-66s %s%n", ok ? "PASS" : "FAIL", name, detail); if (ok) pass++; else fail++;
    }
    /** Run body on a worker with a deadline; on timeout interrupt it (frees the library's waits). */
    static <T> Object within(long ms, Callable<T> body) {
        ExecutorService ex = Executors.newSingleThreadExecutor(r -> { Thread t = new Thread(r); t.setDaemon(true); return t; });
        Future<T> f = ex.submit(body);
        try { return f.get(ms, TimeUnit.MILLISECONDS); }
        catch (TimeoutException e) { f.cancel(true); return "HANG"; }
        catch (ExecutionException e) { return e.getCause(); }
        catch (InterruptedException e) { return e; }
        finally { ex.shutdownNow(); }
    }
    // The app's old way (AdbManager before this change): read to the end of the stream.
    static String oldWay(Mgr m, String cmd) throws Exception {
        AdbStream s = m.openStream("shell:" + cmd);
        String body = new BufferedReader(new InputStreamReader(s.openInputStream())).lines().reduce("", (a, b) -> a + b + "\n");
        s.close(); return body;
    }
    // The app's new way (AdbManager.runToMarker).
    static String newWay(Mgr m, String cmd) throws Exception {
        String mark = AdbRead.newMarker();
        AdbStream s = m.openStream("shell:" + AdbRead.wrap(cmd, mark));
        try { return AdbRead.untilMarker(s.openInputStream(), mark).output; } finally { try { s.close(); } catch (Throwable t) {} }
    }
    static void race(FakeAdbd d, String name, String out, int chunk, long gap, boolean closeBeforeOkay, int runs) throws Exception {
        d.output = out; d.chunk = chunk; d.chunkGapMs = gap; d.closeBeforeOkay = closeBeforeOkay;
        // ADBLAB_ONLY_NEW: skip the old way (its hangs cost 2 s each) — the CI gate.
        for (int way = System.getenv("ADBLAB_ONLY_NEW") != null ? 1 : 0; way < 2; way++) {
            int ok = 0, threw = 0, hung = 0, wrong = 0;
            Mgr m = new Mgr(); m.setTimeout(3000, TimeUnit.MILLISECONDS);
            for (int i = 0; i < runs; i++) {
                if (!m.isConnected()) { try { m.disconnect(); } catch (Throwable t) {} m.connect("127.0.0.1", d.port()); }
                final Mgr mm = m; final int w = way;
                Object r = within(2000, () -> w == 0 ? oldWay(mm, "cmd") : newWay(mm, "cmd"));
                if (r instanceof String && !"HANG".equals(r)) {
                    String got = (String) r; String want = out;
                    boolean same = w == 0 ? got.replaceAll("\n$", "").equals(want.replaceAll("\n$", "")) : got.equals(want);
                    if (same) ok++; else wrong++;
                } else if ("HANG".equals(r)) { hung++; m.disconnect(); }
                else threw++;
            }
            m.disconnect();
            String label = (way == 0 ? "old (read to end) " : "new (end marker)  ") + name;
            String detail = String.format("%d/%d ok, %d threw, %d hung, %d wrong", ok, runs, threw, hung, wrong);
            if (way == 0) System.out.printf("info %-66s %s%n", label, detail);
            else check(label, ok == runs, detail);
        }
    }
    public static void main(String[] a) throws Exception {
        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (InputStream in = new FileInputStream(a[0])) { ks.load(in, "labpass".toCharArray()); }
        KEY = (PrivateKey) ks.getKey("lab", "labpass".toCharArray()); CERT = ks.getCertificate("lab");
        StringBuilder scan = new StringBuilder();
        for (int i = 0; i < 400; i++) scan.append("734003200|/storage/emulated/0/Android/data/org.telegram.messenger/files/Telegram/Telegram Video/ဇာတ်ကား ").append(i).append(".mp4\n");
        String scanOut = scan.toString().trim();
        int runs = Integer.parseInt(a.length > 1 ? a[1] : "150");
        try (FakeAdbd d = new FakeAdbd()) {
            System.out.println("-- 1. reading a command's output, " + runs + " runs each (real library, real socket)");
            race(d, "id: one packet, close at once", "uid=2000(shell) gid=2000(shell)", 4096, 0, true, runs);
            race(d, "id: one packet, close after OKAY", "uid=2000(shell) gid=2000(shell)", 4096, 0, false, runs);
            race(d, "true / probe: no output", "", 4096, 0, true, runs);
            race(d, "scan: 50 KB in 4 KB packets", scanOut, 4096, 0, true, runs / 3);
            race(d, "scan: output trickling out (5 ms between packets)", scanOut, 4096, 5, true, runs / 5);

            System.out.println("-- 1b. the end marker's edges");
            race(d, "Burmese names, 7-byte packets (marker and UTF-8 split)", "/x/\u1007\u102c\u1010\u103a\u1000\u102c\u1038 \u1041.mp4\nok", 7, 0, true, 30);
            {
                d.output = scanOut; d.chunk = 4096; d.chunkGapMs = 0; d.omitMarker = true;
                Mgr m = new Mgr(); m.setTimeout(3000, TimeUnit.MILLISECONDS); m.connect("127.0.0.1", d.port());
                // Never an answer. Either the library ends the read at once, or
                // (output still queued when adbd closed) its read waits, and the
                // deadline every app read runs under (runWithDeadline) ends it.
                Object r = within(2000, () -> newWay(m, "cmd"));
                boolean failed = r instanceof IOException || "HANG".equals(r);
                check("shell dies before the marker: a failure, never an answer", failed,
                        r instanceof IOException ? "cut off at once" : "HANG".equals(r) ? "cut off at the deadline" : "returned " + r);
                m.disconnect(); d.omitMarker = false;
            }
            System.out.println("-- 1c. file ranges (streamRange, thumbnails, the 4-byte probe)");
            for (int[] c : new int[][] {{4, 4, 0}, {1 << 20, 1 << 20, 0}, {10000, 20000, 0}, {10000, 20000, 1}}) {
                int have = c[0], ask = c[1]; boolean silent = c[2] == 1;
                byte[] f = new byte[have]; new Random(have).nextBytes(f);
                d.file = f; d.neverClose = silent; d.chunk = 64 * 1024;
                Mgr m = new Mgr(); m.setTimeout(3000, TimeUnit.MILLISECONDS); m.connect("127.0.0.1", d.port());
                ByteArrayOutputStream sink = new ByteArrayOutputStream();
                long t0 = System.currentTimeMillis();
                Object r = within(5000, () -> {
                    AdbStream s = m.openStream("exec:dd");
                    try { return AdbRead.copyExactly(s.openInputStream(), ask, sink, 800); } finally { s.close(); }
                });
                long took = System.currentTimeMillis() - t0;
                long want = Math.min(have, ask);
                boolean ok = Long.valueOf(want).equals(r) && Arrays.equals(sink.toByteArray(), Arrays.copyOf(f, (int) want));
                String name = have == ask ? "exactly " + ask + " bytes" : silent ? "file shorter than asked, then silence (stall guard)" : "file shorter than asked, then closed";
                check("range: " + name, ok && took < 3000, r + " bytes in " + took + " ms");
                m.disconnect();
            }
            d.neverClose = false;

            System.out.println("-- 2. a port that accepts TCP but never speaks ADB (the 30 s sweep port)");
            d.speak = false;
            for (long timeout : new long[] {Long.MAX_VALUE, 1500}) {
                Mgr m = new Mgr(); m.setTimeout(timeout, TimeUnit.MILLISECONDS);
                Thread c = new Thread(() -> { try { m.connect("127.0.0.1", d.port()); } catch (Throwable t) {} }); c.setDaemon(true); c.start();
                Thread.sleep(200);
                long t0 = System.currentTimeMillis();
                Object r = within(4000, () -> m.isConnected());
                long waited = System.currentTimeMillis() - t0;
                String label = timeout == Long.MAX_VALUE ? "library default (no timeout): isConnected() elsewhere"
                        : "connect given a 1.5 s budget: isConnected() elsewhere";
                if (timeout == Long.MAX_VALUE) System.out.printf("info %-66s %s%n", label, "HANG".equals(r) ? "blocked > 4 s (frozen)" : "answered in " + waited + " ms");
                else check(label, Boolean.FALSE.equals(r) && waited < 1800, "answered in " + waited + " ms");
                for (java.net.Socket s : d.clients) try { s.close(); } catch (IOException e) {}
                c.join(3000);
            }
            d.speak = true;

            System.out.println("-- 3. a stream adbd never OKAYs: freeing the stuck worker");
            d.answerOpen = false;
            for (int order = 0; order < 2; order++) {
                Mgr m = new Mgr(); m.setTimeout(3000, TimeUnit.MILLISECONDS); m.connect("127.0.0.1", d.port());
                Thread w = new Thread(() -> { try { m.openStream("shell:x"); } catch (Throwable t) {} }); w.setDaemon(true); w.start();
                Thread.sleep(300);
                long t0 = System.currentTimeMillis();
                if (order == 0) {
                    Object r = within(3000, () -> { m.disconnect(); return "done"; });
                    System.out.printf("info %-66s %s%n", "old order: disconnect() first", "HANG".equals(r) ? "disconnect blocked > 3 s behind the worker" : "returned in " + (System.currentTimeMillis() - t0) + " ms");
                    w.interrupt(); w.join(2000);
                } else {
                    w.interrupt(); w.join(1000);
                    boolean freed = !w.isAlive();
                    Object r = within(3000, () -> { m.disconnect(); return "done"; });
                    long took = System.currentTimeMillis() - t0;
                    check("new order: interrupt first, then disconnect()", freed && "done".equals(r) && took < 1500, "worker freed and disconnected in " + took + " ms");
                }
            }
            d.answerOpen = true;
        }
        System.out.println("\n" + pass + " passed, " + fail + " failed");
        System.exit(fail == 0 ? 0 : 1);
    }
}
