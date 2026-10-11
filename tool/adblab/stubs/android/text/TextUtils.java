package android.text;
public class TextUtils {
  public static String join(CharSequence d, Object[] t){ StringBuilder b=new StringBuilder(); for(int i=0;i<t.length;i++){ if(i>0)b.append(d); b.append(t[i]); } return b.toString(); }
  public static String join(CharSequence d, Iterable<?> t){ StringBuilder b=new StringBuilder(); boolean f=true; for(Object o:t){ if(!f)b.append(d); f=false; b.append(o);} return b.toString(); }
}
