package lab;
import java.io.*;
import java.net.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/**
 * A minimal adbd for the lab: speaks the ADB wire protocol (CNXN, OPEN, OKAY,
 * WRTE, CLSE) with flow control — the next WRTE only after the client's OKAY,
 * as adbd does — and answers each shell command per the current scenario.
 */
public class FakeAdbd implements Closeable {
    static final int CNXN = 0x4e584e43, OPEN = 0x4e45504f, OKAY = 0x59414b4f, CLSE = 0x45534c43, WRTE = 0x45545257;
    public volatile int chunk = 4096;          // payload size
    public volatile long chunkGapMs = 0;        // pause between chunks (output trickling out)
    public volatile boolean closeBeforeOkay = true; // CLSE right after the last WRTE, not after its OKAY
    public volatile String output = "";         // what the command prints
    public volatile boolean answerOpen = true;   // false: never OKAY an OPEN (stuck stream)
    public volatile boolean speak = true;        // false: accept TCP, never answer (not adb)
    public volatile boolean omitMarker = false;  // the shell dies before printing the marker
    public volatile byte[] file = new byte[0];   // what an exec: (dd/cat) stream sends
    public volatile boolean neverClose = false;  // send what there is, then go silent
    final ServerSocket server;
    final List<Socket> clients = new CopyOnWriteArrayList<>();
    public FakeAdbd() throws IOException {
        server = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
        Thread t = new Thread(this::acceptLoop, "fake-adbd"); t.setDaemon(true); t.start();
    }
    public int port() { return server.getLocalPort(); }
    void acceptLoop() {
        while (!server.isClosed()) {
            try { Socket s = server.accept(); clients.add(s); Thread t = new Thread(() -> serve(s), "fake-adbd-conn"); t.setDaemon(true); t.start(); }
            catch (IOException e) { return; }
        }
    }
    static int sum(byte[] p) { int s = 0; for (byte b : p) s += b & 0xff; return s; }
    static synchronized void send(OutputStream out, int cmd, int a0, int a1, byte[] p) throws IOException {
        ByteBuffer h = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN);
        h.putInt(cmd).putInt(a0).putInt(a1).putInt(p.length).putInt(sum(p)).putInt(~cmd);
        out.write(h.array()); if (p.length > 0) out.write(p); out.flush();
    }
    void serve(Socket s) {
        Map<Integer, Semaphore> okays = new ConcurrentHashMap<>();
        int nextRemote = 1000;
        try {
            DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream()));
            OutputStream out = s.getOutputStream();
            byte[] hb = new byte[24];
            while (true) {
                in.readFully(hb);
                ByteBuffer h = ByteBuffer.wrap(hb).order(ByteOrder.LITTLE_ENDIAN);
                int cmd = h.getInt(), a0 = h.getInt(), a1 = h.getInt(), len = h.getInt();
                byte[] p = new byte[len]; in.readFully(p);
                if (!speak) continue;
                if (cmd == CNXN) {
                    synchronized (FakeAdbd.class) { send(out, CNXN, 0x01000001, 256 * 1024, "device::ro.product.name=lab;".getBytes()); }
                } else if (cmd == OPEN) {
                    if (!answerOpen) continue;
                    int local = a0, remote = nextRemote++;
                    String dest = new String(p, StandardCharsets.UTF_8).replace("\0", "");
                    Semaphore ok = new Semaphore(0); okays.put(remote, ok);
                    synchronized (FakeAdbd.class) { send(out, OKAY, remote, local, new byte[0]); }
                    Thread r = new Thread(() -> respond(out, dest, local, remote, ok), "fake-adbd-cmd"); r.setDaemon(true); r.start();
                } else if (cmd == OKAY) {
                    Semaphore ok = okays.get(a1); if (ok != null) ok.release();
                }
            }
        } catch (IOException e) { /* client went away */ }
    }
    void respond(OutputStream out, String dest, int local, int remote, Semaphore ok) {
        try {
            byte[] all;
            if (dest.startsWith("exec:")) {
                all = file;
            } else {
                String text = output;
                // A command sent by AdbRead.wrap: print the marker line after it, as sh would.
                java.util.regex.Matcher m = java.util.regex.Pattern.compile("echo (__innocent_end_[0-9a-f]+__)\\$__innocent_rc").matcher(dest);
                if (m.find() && !omitMarker) text = text + "\n" + m.group(1) + "0\n";
                all = text.getBytes(StandardCharsets.UTF_8);
            }
            int c = chunk;
            for (int i = 0; i < all.length; i += c) {
                byte[] part = Arrays.copyOfRange(all, i, Math.min(all.length, i + c));
                synchronized (FakeAdbd.class) { send(out, WRTE, remote, local, part); }
                boolean last = i + c >= all.length;
                if (!(last && closeBeforeOkay)) ok.tryAcquire(5, TimeUnit.SECONDS);
                if (chunkGapMs > 0 && !last) Thread.sleep(chunkGapMs);
            }
            if (neverClose) return;
            synchronized (FakeAdbd.class) { send(out, CLSE, remote, local, new byte[0]); }
        } catch (Exception e) { }
    }
    public void close() throws IOException { server.close(); for (Socket s : clients) try { s.close(); } catch (IOException e) {} }
}
