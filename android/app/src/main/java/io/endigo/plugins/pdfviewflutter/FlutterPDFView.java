/*
 * MIT License
 *
 * Copyright (c) 2019 endigo
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
package io.endigo.plugins.pdfviewflutter;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.View;
import android.net.Uri;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.platform.PlatformView;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import com.github.barteksc.pdfviewer.PDFView;
import com.github.barteksc.pdfviewer.PDFView.Configurator;
import com.github.barteksc.pdfviewer.PdfViewGeometryBridge;
import com.github.barteksc.pdfviewer.listener.*;
import com.github.barteksc.pdfviewer.util.Constants;
import com.github.barteksc.pdfviewer.util.FitPolicy;

import com.github.barteksc.pdfviewer.link.LinkHandler;

import com.shockwave.pdfium.util.SizeF;

/**
 * [G2] 本文件 vendoring 自 flutter_pdfview 1.4.4 (MIT, Copyright (c) 2019 endigo)。
 * 上游: https://github.com/endigo/flutter_pdfview
 *
 * <p>本项目改动(其余部分与上游一致):
 * <ol>
 *   <li>接上 {@code .onTap()}: 把点击位置换算成**页面坐标**回传 Flutter, 供点击朗读定位字符;</li>
 *   <li>接上 {@code .onDraw()}: 绘制高亮框, 并经 {@link PdfViewGeometryBridge}
 *       修正上游次轴偏移写死为 0 的缺陷;</li>
 *   <li>新增 {@code setHighlights} / {@code clearHighlights} 两个 MethodChannel 方法。</li>
 * </ol>
 */
public class FlutterPDFView implements PlatformView, MethodCallHandler {
    private final PDFView pdfView;
    private final MethodChannel methodChannel;
    private final LinkHandler linkHandler;

    /** [G2] 待绘制的高亮框, 单位为**页面坐标(PDF 点)**, 与 PDFBox 输出同一坐标系 */
    private final List<RectF> highlights = new ArrayList<>();

    /** [G2] 高亮框所属页; -1 表示无 */
    private int highlightPage = -1;

    /** [G2] 高亮填充画笔, 半透明避免遮挡原文 */
    private final Paint highlightPaint = new Paint();

    @SuppressWarnings("unchecked")
    FlutterPDFView(Context context, BinaryMessenger messenger, int id, Map<String, Object> params) {
        pdfView = new PDFView(context, null);
        final boolean preventLinkNavigation = getBoolean(params, "preventLinkNavigation");

        methodChannel = new MethodChannel(messenger, "plugins.endigo.io/pdfview_" + id);
        methodChannel.setMethodCallHandler(this);

        linkHandler = new PDFLinkHandler(context, pdfView, methodChannel, preventLinkNavigation);

        highlightPaint.setStyle(Paint.Style.FILL);
        highlightPaint.setAntiAlias(true);
        highlightPaint.setColor(Color.argb(80, 255, 200, 0));

        pdfView.useBestQuality(getBoolean(params, "useBestQuality"));
        pdfView.enableRenderDuringScale(getBoolean(params, "enableRenderDuringScale"));
        Float thumbnailRatio = getFloat(params, "thumbnailRatio");

        if (thumbnailRatio != null) {
            Constants.THUMBNAIL_RATIO = thumbnailRatio;
        }

        Configurator config = null;
        if (params.get("filePath") != null) {
            String filePath = (String) params.get("filePath");
            config = pdfView.fromUri(getURI(filePath));
        } else if (params.get("pdfData") != null) {
            byte[] data = (byte[]) params.get("pdfData");
            config = pdfView.fromBytes(data);
        }

        Object backgroundColor = params.get("backgroundColor");
        if (backgroundColor != null) {
            int color = ((Number) backgroundColor).intValue();
            pdfView.setBackgroundColor(color);
        }

        if (config != null) {
            config
                    .enableSwipe(getBoolean(params, "enableSwipe"))
                    .swipeHorizontal(getBoolean(params, "swipeHorizontal"))
                    .password(getString(params, "password"))
                    .nightMode(getBoolean(params, "nightMode"))
                    .autoSpacing(getBoolean(params, "autoSpacing"))
                    .pageFling(getBoolean(params, "pageFling"))
                    .pageSnap(getBoolean(params, "pageSnap"))
                    .pageFitPolicy(getFitPolicy(params))
                    .enableAnnotationRendering(true)
                    .linkHandler(linkHandler)
                    .enableAntialiasing(getBoolean(params, "enableAntialiasing"))
                    .enableDoubletap(true)
                    .defaultPage(getInt(params, "defaultPage"))
                    // [G2] 点击 → 页面坐标, 换算配方照抄上游 DragPinchManager
                    .onTap(new OnTapListener() {
                        @Override
                        public boolean onTap(MotionEvent e) {
                            dispatchTap(e);
                            // 返回 false: 不吞掉事件, 保留上游滚动条切换等既有行为
                            return false;
                        }
                    })
                    // [G2] 绘制高亮框(仅当前页)
                    .onDraw(new OnDrawListener() {
                        @Override
                        public void onLayerDrawn(Canvas canvas, float pageWidth,
                                                 float pageHeight, int displayedPage) {
                            drawHighlights(canvas, pageWidth, pageHeight, displayedPage);
                        }
                    })
                    .onPageChange(new OnPageChangeListener() {
                        @Override
                        public void onPageChanged(int page, int total) {
                            Map<String, Object> args = new HashMap<>();
                            args.put("page", page);
                            args.put("total", total);
                            methodChannel.invokeMethod("onPageChanged", args);
                        }
                    })
                    .onError(new OnErrorListener() {
                        @Override
                        public void onError(Throwable t) {
                            Map<String, Object> args = new HashMap<>();
                            args.put("error", t.toString());
                            methodChannel.invokeMethod("onError", args);
                        }
                    }).onPageError(new OnPageErrorListener() {
                        @Override
                        public void onPageError(int page, Throwable t) {
                            Map<String, Object> args = new HashMap<>();
                            args.put("page", page);
                            args.put("error", t.toString());
                            methodChannel.invokeMethod("onPageError", args);
                        }
                    }).onRender(new OnRenderListener() {
                        @Override
                        public void onInitiallyRendered(int pages) {
                            Map<String, Object> args = new HashMap<>();
                            args.put("pages", pages);
                            methodChannel.invokeMethod("onRender", args);
                        }
                    })
                    .load();
        }
    }

    /**
     * [G2] 把触摸点换算为页面坐标(PDF 点)并回传 Flutter。
     *
     * <p>换算配方照抄上游 {@code DragPinchManager#onSingleTapConfirmed}: 先减去
     * 视图滚动偏移得到文档坐标, 再定位页码, 最后减去该页主/次轴偏移得到页内坐标,
     * 除以 zoom 还原为未缩放的页面坐标。与 {@link #drawHighlights} 共用同一套换算,
     * 保证「点中的位置」与「画框的位置」严格同源。
     */
    private void dispatchTap(MotionEvent e) {
        if (!PdfViewGeometryBridge.isReady(pdfView)) {
            return;
        }

        float mappedX = -pdfView.getCurrentXOffset() + e.getX();
        float mappedY = -pdfView.getCurrentYOffset() + e.getY();
        boolean vertical = pdfView.isSwipeVertical();
        int page = PdfViewGeometryBridge.getPageAtOffset(pdfView, vertical ? mappedY : mappedX);

        float primary = PdfViewGeometryBridge.getPageOffset(pdfView, page);
        float secondary = PdfViewGeometryBridge.getSecondaryPageOffset(pdfView, page);
        float pageLeft = vertical ? secondary : primary;
        float pageTop = vertical ? primary : secondary;

        float zoom = pdfView.getZoom();
        if (zoom <= 0f) {
            return;
        }
        // 页内坐标(未缩放): 与 PDFBox 的 CropBox 左上原点坐标系一致
        float x = (mappedX - pageLeft) / zoom;
        float y = (mappedY - pageTop) / zoom;

        SizeF size = PdfViewGeometryBridge.getPageSize(pdfView, page);
        // 落在页间空白处则不上报, 避免 Flutter 侧收到越界坐标
        if (x < 0f || y < 0f || x > size.getWidth() || y > size.getHeight()) {
            return;
        }

        Map<String, Object> args = new HashMap<>();
        args.put("page", page);
        args.put("x", (double) x);
        args.put("y", (double) y);
        args.put("pageWidth", (double) size.getWidth());
        args.put("pageHeight", (double) size.getHeight());
        methodChannel.invokeMethod("onTap", args);
    }

    /**
     * [G2] 在当前页上绘制高亮框。
     *
     * <p>上游在回调前已把画布平移到页面原点并按 zoom 缩放, 故 [pageWidth] 是**已缩放**
     * 的页宽, 缩放比例可直接由 {@code pageWidth / size.getWidth()} 得出, 无需自行读 zoom。
     *
     * <p>但上游 {@code drawWithListener} 在竖向滚动时把次轴(X)偏移写死为 0, 与真正绘页的
     * {@code drawPart} 所用的居中偏移不一致——各页等宽时差值为 0 故未暴露, 页宽不一时框会
     * 整体水平错位。此处用 {@link PdfViewGeometryBridge#getSecondaryPageOffset} 补偿。
     */
    private void drawHighlights(Canvas canvas, float pageWidth, float pageHeight, int displayedPage) {
        if (highlightPage != displayedPage || highlights.isEmpty()) {
            return;
        }
        SizeF size = PdfViewGeometryBridge.getPageSize(pdfView, displayedPage);
        if (size.getWidth() <= 0f || size.getHeight() <= 0f) {
            return;
        }
        float sx = pageWidth / size.getWidth();
        float sy = pageHeight / size.getHeight();

        // 修正上游次轴偏移: 竖向滚动补 X, 横向滚动补 Y
        float secondary = PdfViewGeometryBridge.getSecondaryPageOffset(pdfView, displayedPage);
        float fixX = pdfView.isSwipeVertical() ? secondary : 0f;
        float fixY = pdfView.isSwipeVertical() ? 0f : secondary;

        int saved = canvas.save();
        canvas.translate(fixX, fixY);
        for (RectF r : highlights) {
            canvas.drawRect(r.left * sx, r.top * sy, r.right * sx, r.bottom * sy, highlightPaint);
        }
        canvas.restoreToCount(saved);
    }

    @Override
    public View getView() {
        return pdfView;
    }

    @Override
    public void onMethodCall(MethodCall methodCall, Result result) {
        switch (methodCall.method) {
            case "pageCount":
                getPageCount(result);
                break;
            case "currentPage":
                getCurrentPage(result);
                break;
            case "setPage":
                setPage(methodCall, result);
                break;
            case "updateSettings":
                updateSettings(methodCall, result);
                break;
            // [G2] 高亮框下发/清除
            case "setHighlights":
                setHighlights(methodCall, result);
                break;
            case "clearHighlights":
                clearHighlights(result);
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    void getPageCount(Result result) {
        result.success(pdfView.getPageCount());
    }

    void getCurrentPage(Result result) {
        result.success(pdfView.getCurrentPage());
    }

    void setPage(MethodCall call, Result result) {
        if (call.argument("page") != null) {
            int page = (int) call.argument("page");
            pdfView.jumpTo(page);
        }

        result.success(true);
    }

    /**
     * [G2] 设置高亮框。入参 {@code rects} 为页面坐标(PDF 点)的
     * {@code [left, top, right, bottom]} 四元组列表。
     */
    @SuppressWarnings("unchecked")
    private void setHighlights(MethodCall call, Result result) {
        Integer page = call.argument("page");
        List<List<Double>> rects = call.argument("rects");
        highlights.clear();
        highlightPage = page == null ? -1 : page;
        if (rects != null) {
            for (List<Double> r : rects) {
                if (r == null || r.size() < 4) {
                    continue;
                }
                highlights.add(new RectF(
                        r.get(0).floatValue(), r.get(1).floatValue(),
                        r.get(2).floatValue(), r.get(3).floatValue()));
            }
        }
        pdfView.invalidate();
        result.success(true);
    }

    /** [G2] 清除高亮框 */
    private void clearHighlights(Result result) {
        highlights.clear();
        highlightPage = -1;
        pdfView.invalidate();
        result.success(true);
    }

    @SuppressWarnings("unchecked")
    private void updateSettings(MethodCall methodCall, Result result) {
        applySettings((Map<String, Object>) methodCall.arguments);
        result.success(null);
    }

    private void applySettings(Map<String, Object> settings) {
        for (String key : settings.keySet()) {
            switch (key) {
                case "enableSwipe":
                    pdfView.setSwipeEnabled(getBoolean(settings, key));
                    break;
                case "nightMode":
                    pdfView.setNightMode(getBoolean(settings, key));
                    break;
                case "pageFling":
                    pdfView.setPageFling(getBoolean(settings, key));
                    break;
                case "pageSnap":
                    pdfView.setPageSnap(getBoolean(settings, key));
                    break;
                case "preventLinkNavigation":
                    final PDFLinkHandler plh = (PDFLinkHandler) this.linkHandler;
                    plh.setPreventLinkNavigation(getBoolean(settings, key));
                    break;
                default:
                    throw new IllegalArgumentException("Unknown PDFView setting: " + key);
            }
        }
    }

    @Override
    public void dispose() {
        methodChannel.setMethodCallHandler(null);
    }

    private boolean getBoolean(Map<String, Object> params, String key) {
        return params.containsKey(key) ? (boolean) params.get(key) : false;
    }

    private String getString(Map<String, Object> params, String key) {
        return params.containsKey(key) ? (String) params.get(key) : "";
    }

    private int getInt(Map<String, Object> params, String key) {
        return params.containsKey(key) ? (int) params.get(key) : 0;
    }

    private Float getFloat(Map<String, Object> params, String key) {
        if (!params.containsKey(key)) {
            return null;
        }
        Object value = params.get(key);
        if (value instanceof Number) {
            return ((Number) value).floatValue();
        }
        return null;
    }

    private FitPolicy getFitPolicy(Map<String, Object> params) {
        String fitPolicy = getString(params, "fitPolicy");
        switch (fitPolicy) {
            case "FitPolicy.WIDTH":
                return FitPolicy.WIDTH;
            case "FitPolicy.HEIGHT":
                return FitPolicy.HEIGHT;
            case "FitPolicy.BOTH":
            default:
                return FitPolicy.BOTH;
        }
    }

    private Uri getURI(final String uri) {
        Uri parsed = Uri.parse(uri);

        if (parsed.getScheme() == null || parsed.getScheme().isEmpty()) {
            return Uri.fromFile(new File(uri));
        }
        return parsed;
    }

}
