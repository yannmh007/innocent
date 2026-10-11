package io.github.muntashirakon.adb.android;
import android.content.Context;
import java.net.InetAddress;
/** Lab stub: discovery is not under test. */
public class AdbMdns {
  public static final String SERVICE_TYPE_ADB = "adb";
  public static final String SERVICE_TYPE_TLS_PAIRING = "adb-tls-pairing";
  public static final String SERVICE_TYPE_TLS_CONNECT = "adb-tls-connect";
  public @interface ServiceType {}
  public interface OnAdbDaemonDiscoveredListener { void onPortChanged(InetAddress hostAddress, int port); }
  public AdbMdns(Context c, String t, OnAdbDaemonDiscoveredListener l) {}
  public void start() {} public void stop() {} public boolean isRunning() { return false; }
}
