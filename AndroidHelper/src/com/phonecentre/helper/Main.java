package com.phonecentre.helper;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.res.AssetManager;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.MediaMetadataRetriever;
import android.media.ThumbnailUtils;
import android.os.Build;
import android.util.Size;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.Base64;
import android.util.DisplayMetrics;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.PrintStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * 在裝置上以 shell 身分透過 app_process 執行：
 *   CLASSPATH=/data/local/tmp/phonecentre-helper.jar app_process / com.phonecentre.helper.Main <cmd> [args]
 *
 * 指令：
 *   list                 每行輸出「package \t label \t isSystem(0/1)」，只列出有啟動器入口的 App
 *   icons <px> <pkg...>  每行輸出「package \t base64(PNG)」
 *   thumbs <px> <path...> 每行輸出「path \t base64(JPEG)」，在手機端產生縮圖，只傳小圖
 *   removetasks <id...>  從最近使用移除 task（跟手動滑掉一樣；常駐程序的 App 用 force-stop 清不掉）
 *   tobg <prev> <id...>  把 root task 搬到主螢幕，同一個程序內立刻把 prev（主螢幕原本最上層的 task，-1 = 不處理）
 *                        拉回最上層：兩個動作間隔不到 1ms，App 不會在主螢幕上閃一下
 *   power <0|2>          主螢幕面板關閉（0）／開啟（2），手機本身保持開機（跟 scrcpy 的關閉螢幕相同做法）
 *   gesture <ms> <x,y...> 在主螢幕注入一筆觸控：第一點按下、依序移動、最後一點放開；每點間隔 ms 毫秒
 */
public final class Main {

    private static PrintStream out;
    private static PackageManager pm;

    public static void main(String[] args) {
        out = new PrintStream(System.out, false);
        if (args.length == 0) {
            System.err.println("usage: list | icons <px> <pkg...>");
            System.exit(2);
        }
        // 縮圖也要初始化系統 Context：三星的 MediaMetadataRetriever 內部會用到
        try {
            pm = obtainPackageManager();
        } catch (Throwable t) {
            pm = null;
        }
        try {
            switch (args[0]) {
                case "list":
                    list();
                    break;
                case "icons":
                    int px = Integer.parseInt(args[1]);
                    for (int i = 2; i < args.length; i++) icon(args[i], px);
                    break;
                case "thumbs":
                    int tpx = Integer.parseInt(args[1]);
                    for (int i = 2; i < args.length; i++) thumb(args[i], tpx);
                    break;
                case "removetasks":
                    for (int i = 1; i < args.length; i++) out.println(args[i] + "\t" + (removeTask(Integer.parseInt(args[i])) ? 1 : 0));
                    break;
                case "tobg":
                    toBackground(args);
                    break;
                case "power":
                    out.println(setPanelPower(Integer.parseInt(args[1])) ? "ok" : "fail");
                    break;
                case "gesture":
                    gesture(args);
                    out.println("ok");
                    break;
                default:
                    System.err.println("unknown command " + args[0]);
                    System.exit(2);
            }
        } catch (Throwable t) {
            t.printStackTrace();
            System.exit(1);
        }
        out.flush();
        System.exit(0);
    }

    // ---- Context / PackageManager ----

    private static PackageManager obtainPackageManager() throws Exception {
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread;
        try {
            thread = at.getMethod("systemMain").invoke(null);
        } catch (Throwable t) {
            Constructor<?> c = at.getDeclaredConstructor();
            c.setAccessible(true);
            thread = c.newInstance();
        }
        Context ctx = (Context) at.getMethod("getSystemContext").invoke(thread);
        return ctx.getPackageManager();
    }

    // ---- list ----

    private static void list() throws Exception {
        Set<String> seen = new HashSet<>();
        if (pm != null) {
            Intent intent = new Intent(Intent.ACTION_MAIN);
            intent.addCategory(Intent.CATEGORY_LAUNCHER);
            List<ResolveInfo> infos = pm.queryIntentActivities(intent, 0);
            for (ResolveInfo ri : infos) {
                ApplicationInfo ai = ri.activityInfo.applicationInfo;
                if (!seen.add(ai.packageName)) continue;
                String label = safeLabel(ai);
                boolean sys = (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0
                        && (ai.flags & ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0;
                out.println(ai.packageName + "\t" + clean(label) + "\t" + (sys ? 1 : 0));
            }
        }
        out.flush();
    }

    private static String safeLabel(ApplicationInfo ai) {
        try {
            CharSequence cs = pm.getApplicationLabel(ai);
            if (cs != null && cs.length() > 0) return cs.toString();
        } catch (Throwable ignored) {
        }
        try {
            Resources r = resourcesFor(ai);
            if (ai.labelRes != 0) return r.getString(ai.labelRes);
        } catch (Throwable ignored) {
        }
        return ai.packageName;
    }

    private static String clean(String s) {
        return s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ');
    }

    // ---- icons ----

    private static void icon(String pkg, int px) {
        try {
            Drawable d = null;
            ApplicationInfo ai = null;
            if (pm != null) {
                ai = pm.getApplicationInfo(pkg, 0);
                try {
                    d = pm.getApplicationIcon(ai);
                } catch (Throwable ignored) {
                }
            }
            if (d == null && ai != null) {
                Resources r = resourcesFor(ai);
                d = r.getDrawableForDensity(ai.icon, DisplayMetrics.DENSITY_XXXHIGH, null);
            }
            if (d == null) return;
            Bitmap bmp = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(bmp);
            d.setBounds(0, 0, px, px);
            d.draw(c);
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            bmp.compress(Bitmap.CompressFormat.PNG, 100, bos);
            out.println(pkg + "\t" + Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP));
            out.flush();
        } catch (Throwable t) {
            System.err.println("icon " + pkg + ": " + t);
        }
    }

    // ---- thumbs ----

    private static void thumb(String path, int px) {
        try {
            String lower = path.toLowerCase(Locale.ROOT);
            boolean video = lower.endsWith(".mp4") || lower.endsWith(".mov") || lower.endsWith(".3gp")
                    || lower.endsWith(".mkv") || lower.endsWith(".webm");
            Bitmap bmp = null;
            File f = new File(path);
            if (Build.VERSION.SDK_INT >= 29) {
                try {
                    Size size = new Size(px, px);
                    bmp = video ? ThumbnailUtils.createVideoThumbnail(f, size, null)
                                : ThumbnailUtils.createImageThumbnail(f, size, null);
                } catch (Throwable ignored) {
                }
            }
            if (bmp == null && video) {
                MediaMetadataRetriever r = new MediaMetadataRetriever();
                try {
                    r.setDataSource(path);
                    bmp = r.getFrameAtTime(0);
                } finally {
                    r.release();
                }
            }
            if (bmp == null) {
                BitmapFactory.Options o = new BitmapFactory.Options();
                o.inJustDecodeBounds = true;
                BitmapFactory.decodeFile(path, o);
                int sample = 1;
                while (o.outWidth / (sample * 2) >= px && o.outHeight / (sample * 2) >= px) sample *= 2;
                o = new BitmapFactory.Options();
                o.inSampleSize = sample;
                bmp = BitmapFactory.decodeFile(path, o);
            }
            if (bmp == null) return;
            if (!video) bmp = applyExifOrientation(path, bmp);
            // 縮成短邊 px
            int w = bmp.getWidth(), h = bmp.getHeight();
            float scale = (float) px / Math.min(w, h);
            if (scale < 1f) bmp = Bitmap.createScaledBitmap(bmp, Math.max(1, Math.round(w * scale)), Math.max(1, Math.round(h * scale)), true);
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            bmp.compress(Bitmap.CompressFormat.JPEG, 80, bos);
            out.println(path + "\t" + Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP));
            out.flush();
        } catch (Throwable t) {
            System.err.println("thumb " + path + ": " + t);
        }
    }

    /**
     * 部分機型（例如三星的 HEIC）產生的縮圖沒有套用 EXIF 方向。
     * 比對原圖長寬：縮圖仍是未旋轉的比例才轉，避免已經轉過的再轉一次。
     */
    private static Bitmap applyExifOrientation(String path, Bitmap bmp) {
        try {
            int deg = 0, rw = 0, rh = 0;
            String lower = path.toLowerCase(Locale.ROOT);
            if (Build.VERSION.SDK_INT >= 28 && (lower.endsWith(".heic") || lower.endsWith(".heif"))) {
                // HEIF 的旋轉寫在容器的 irot 屬性
                MediaMetadataRetriever r = new MediaMetadataRetriever();
                try {
                    r.setDataSource(path);
                    deg = parseInt(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_IMAGE_ROTATION));
                    rw = parseInt(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_IMAGE_WIDTH));
                    rh = parseInt(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_IMAGE_HEIGHT));
                } finally {
                    r.release();
                }
            }
            if (deg == 0) {
                ExifInterface exif = new ExifInterface(path);
                switch (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    case ExifInterface.ORIENTATION_ROTATE_90: deg = 90; break;
                    case ExifInterface.ORIENTATION_ROTATE_180: deg = 180; break;
                    case ExifInterface.ORIENTATION_ROTATE_270: deg = 270; break;
                    default: return bmp;
                }
            }
            if (deg != 180) {
                if (rw <= 0 || rh <= 0) {
                    BitmapFactory.Options b = new BitmapFactory.Options();
                    b.inJustDecodeBounds = true;
                    BitmapFactory.decodeFile(path, b);
                    rw = b.outWidth;
                    rh = b.outHeight;
                }
                if (rw <= 0 || rh <= 0) return bmp;
                boolean rawLandscape = rw > rh;
                boolean thumbLandscape = bmp.getWidth() > bmp.getHeight();
                if (rawLandscape != thumbLandscape) return bmp;   // 已經轉過了
            }
            Matrix m = new Matrix();
            m.postRotate(deg);
            return Bitmap.createBitmap(bmp, 0, 0, bmp.getWidth(), bmp.getHeight(), m, true);
        } catch (Throwable t) {
            return bmp;
        }
    }

    private static int parseInt(String s) {
        try {
            return s == null ? 0 : Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private static Resources resourcesFor(ApplicationInfo ai) throws Exception {
        Constructor<AssetManager> c = AssetManager.class.getDeclaredConstructor();
        c.setAccessible(true);
        AssetManager am = c.newInstance();
        Method add = AssetManager.class.getDeclaredMethod("addAssetPath", String.class);
        add.setAccessible(true);
        add.invoke(am, ai.sourceDir);
        DisplayMetrics dm = new DisplayMetrics();
        dm.setToDefaults();
        Configuration conf = new Configuration();
        conf.setLocale(Locale.getDefault());
        return new Resources(am, dm, conf);
    }

    // ---- task 操作（IActivityTaskManager，Android 9 以前在 IActivityManager）----

    private static Object taskService() throws Exception {
        try {
            return Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null);
        } catch (ClassNotFoundException e) {
            return Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
        }
    }

    private static Method find(Object svc, String... names) {
        for (String n : names)
            for (Method m : svc.getClass().getMethods())
                if (m.getName().equals(n)) return m;
        return null;
    }

    private static boolean removeTask(int id) {
        try {
            Object svc = taskService();
            Method m = find(svc, "removeTask");
            if (m == null) return false;
            Object r = m.invoke(svc, id);
            return !(r instanceof Boolean) || (Boolean) r;
        } catch (Throwable t) {
            t.printStackTrace();
            return false;
        }
    }

    private static void toBackground(String[] args) throws Exception {
        Object svc = taskService();
        Method move = find(svc, "moveRootTaskToDisplay", "moveStackToDisplay");
        Method front = find(svc, "moveTaskToFront");
        if (move == null) throw new IllegalStateException("no moveRootTaskToDisplay");
        int prev = Integer.parseInt(args[1]);
        for (int i = 2; i < args.length; i++) {
            try { move.invoke(svc, Integer.parseInt(args[i]), 0); } catch (Throwable t) { t.printStackTrace(); }
        }
        if (prev >= 0 && front != null) {
            Class<?>[] p = front.getParameterTypes();
            // Android 10+：(IApplicationThread, callingPackage, taskId, flags, Bundle)；Android 9：(taskId, flags, Bundle)
            if (p.length == 5) front.invoke(svc, null, "com.android.shell", prev, 0, null);
            else if (p.length == 3) front.invoke(svc, prev, 0, null);
        }
        out.println("ok");
    }

    // ---- 面板電源（同 scrcpy：SurfaceControl.setDisplayPowerMode；Android 14+ 的實體顯示器 token 由 DisplayControl 取得）----

    private static boolean setPanelPower(int mode) {
        try {
            Class<?> sc = Class.forName("android.view.SurfaceControl");
            Method set = sc.getMethod("setDisplayPowerMode", android.os.IBinder.class, int.class);
            boolean any = false;
            for (android.os.IBinder token : physicalDisplayTokens(sc)) {
                set.invoke(null, token, mode);
                any = true;
            }
            return any;
        } catch (Throwable t) {
            t.printStackTrace();
            return false;
        }
    }

    private static List<android.os.IBinder> physicalDisplayTokens(Class<?> sc) throws Exception {
        List<android.os.IBinder> list = new java.util.ArrayList<>();
        if (Build.VERSION.SDK_INT >= 34) {
            Class<?> f = Class.forName("com.android.internal.os.ClassLoaderFactory");
            Method create = f.getDeclaredMethod("createClassLoader", String.class, String.class, String.class,
                    ClassLoader.class, int.class, boolean.class, String.class);
            ClassLoader cl = (ClassLoader) create.invoke(null, "/system/framework/services.jar", null, null,
                    ClassLoader.getSystemClassLoader(), 0, true, null);
            Class<?> dc = cl.loadClass("com.android.server.display.DisplayControl");
            Method load = Runtime.class.getDeclaredMethod("loadLibrary0", Class.class, String.class);
            load.setAccessible(true);
            load.invoke(Runtime.getRuntime(), dc, "android_servers");
            long[] ids = (long[]) dc.getMethod("getPhysicalDisplayIds").invoke(null);
            Method tok = dc.getMethod("getPhysicalDisplayToken", long.class);
            for (long id : ids) list.add((android.os.IBinder) tok.invoke(null, id));
        } else if (Build.VERSION.SDK_INT >= 29) {
            long[] ids = (long[]) sc.getMethod("getPhysicalDisplayIds").invoke(null);
            Method tok = sc.getMethod("getPhysicalDisplayToken", long.class);
            for (long id : ids) list.add((android.os.IBinder) tok.invoke(null, id));
        } else {
            list.add((android.os.IBinder) sc.getMethod("getBuiltInDisplay", int.class).invoke(null, 0));
        }
        return list;
    }

    // ---- 觸控注入（同一個程序內連續送出，比每一段都執行一次 input 指令快很多）----

    private static void gesture(String[] args) throws Exception {
        int delay = Integer.parseInt(args[1]);
        int n = args.length - 2;
        if (n < 1) return;
        float[][] pts = new float[n][2];
        for (int i = 0; i < n; i++) {
            String[] xy = args[i + 2].split(",");
            pts[i][0] = Float.parseFloat(xy[0]);
            pts[i][1] = Float.parseFloat(xy[1]);
        }
        Object im;
        Method inject;
        try {
            Class<?> g = Class.forName("android.hardware.input.InputManagerGlobal");
            im = g.getMethod("getInstance").invoke(null);
            inject = g.getMethod("injectInputEvent", android.view.InputEvent.class, int.class);
        } catch (ClassNotFoundException e) {
            Class<?> g = android.hardware.input.InputManager.class;
            im = g.getMethod("getInstance").invoke(null);
            inject = g.getMethod("injectInputEvent", android.view.InputEvent.class, int.class);
        }
        long down = android.os.SystemClock.uptimeMillis();
        for (int i = 0; i < n; i++) {
            int action = i == 0 ? android.view.MotionEvent.ACTION_DOWN
                    : (i == n - 1 ? android.view.MotionEvent.ACTION_UP : android.view.MotionEvent.ACTION_MOVE);
            long now = android.os.SystemClock.uptimeMillis();
            android.view.MotionEvent ev = android.view.MotionEvent.obtain(down, now, action, pts[i][0], pts[i][1], 0);
            ev.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
            // 2 = INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH：等系統處理完再送下一點，軌跡才不會被合併掉
            inject.invoke(im, ev, 2);
            ev.recycle();
            if (delay > 0 && i < n - 1) Thread.sleep(delay);
        }
    }
}
