package org.bouncycastle.util.encoders;
public class Base64 { public static byte[] encode(byte[] b) { return java.util.Base64.getEncoder().encode(b); } }
