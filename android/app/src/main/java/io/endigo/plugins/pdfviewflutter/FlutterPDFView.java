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
 *   <li>[G2.5] 新增 {@code setPageSize} 方法, 并在 {@code dispatchTap} 中按其下发的
 *       CropBox 尺寸把 tap 坐标由「FitPolicy 适配后像素」归一为 PDF 点(修复
 *       G2 真机实测的比例性偏移);</li>
 *   <li>[G2.5] {@code onPageChanged} 中清空旧页高亮, 修复翻回旧页时残留框复现。</li>
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

    /**
     * [G2.5] 各页 CropBox 尺寸(PDF 点), 由 Flutter 侧 {@code setPageSize} 下发。
     *
     * <p>用于把 tap 结果从「FitPolicy 适配后像素」归一到 PDF 点(详见
     * {@link #dispatchTap})。原生侧无法自行取得: PDFBox 在 Flutter 侧的
     * {@code extractTextPositions} 通道里, 而 {@code PdfFile#originalPageSizes}
     * 是上游私有字段, 不属于 {@link PdfViewGeometryBridge} 可只读转发的范围。
     */
    private final android.util.SparseArray<SizeF> pointSizes = new android.util.SparseArray<>();

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
                            // [G2.5] 翻页即弃掉旧页高亮: highlights 此前只按 highlightPage
                            // 过滤而从不清空, 导致翻回旧页时上一次的框会重新出现。
                            if (highlightPage != page && !highlights.isEmpty()) {
                                highlights.clear();
                                highlightPage = -1;
                            }
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
     * 除以 zoom 还原为未缩放的坐标。
     *
     * <p>[G2.5] ⚠️ 到此为止得到的**不是** PDF 点, 而是 <b>FitPolicy 适配后的像素</b>:
     * 上游 {@code PdfFile#getPageSize} 返回的是 {@code pageSizes}(源码注释
     * {@code Scaled page sizes}), 即 {@code PageSizeCalculator} 按视图宽度适配过的
     * 尺寸。绘制侧 {@code drawHighlights} 用 {@code pageWidth / size.getWidth()}
     * 做缩放, 恰好把该比例约掉, 所以 G1/G2 的**画框是对的**; 而 tap 侧此前直接上报
     * 这个像素值, 与 PDFBox 的 PDF 点差了一个适配比例 —— 表现为**偏移量正比于坐标**
     * (左上角原点附近误差≈0, 越往右下越大), 与 zoom / pan 无关(故放大平移后点同一
     * 位置仍得同一字符)。此即 G2 真机验证「仅左上角几个字能命中」的根因。
     *
     * <p>修正: 按 {@code PDF 点 ÷ 适配像素} 归一化。该比例由 Flutter 侧经
     * {@code setPageSize} 下发的 CropBox 尺寸与 {@code getPageSize} 相除得到,
     * 与绘制侧所用比例互为倒数, **两侧仍严格同源**。未下发时(尺寸未知)按 1.0
     * 处理, 退化为修正前行为, 不会崩溃。
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
        // 页内坐标, 单位为「FitPolicy 适配后像素」(尚未归一到 PDF 点)
        float fittedX = (mappedX - pageLeft) / zoom;
        float fittedY = (mappedY - pageTop) / zoom;

        SizeF fitted = PdfViewGeometryBridge.getPageSize(pdfView, page);
        if (fitted.getWidth() <= 0f || fitted.getHeight() <= 0f) {
            return;
        }
        // 落在页间空白处则不上报(在适配像素域判定, 与 fitted 同单位)
        if (fittedX < 0f || fittedY < 0f
                || fittedX > fitted.getWidth() || fittedY > fitted.getHeight()) {
            return;
        }

        // [G2.5] 归一到 PDF 点: 比例 = CropBox 尺寸 ÷ 适配后尺寸
        float pageW = pointSizes.get(page) == null ? 0f : pointSizes.get(page).getWidth();
        float pageH = pointSizes.get(page) == null ? 0f : pointSizes.get(page).getHeight();
        float scaleX = pageW > 0f ? pageW / fitted.getWidth() : 1f;
        float scaleY = pageH > 0f ? pageH / fitted.getHeight() : 1f;
        float x = fittedX * scaleX;
        float y = fittedY * scaleY;

        Map<String, Object> args = new HashMap<>();
        args.put("page", page);
        args.put("x", (double) x);
        args.put("y", (double) y);
        args.put("pageWidth", (double) (pageW > 0f ? pageW : fitted.getWidth()));
        args.put("pageHeight", (double) (pageH > 0f ? pageH : fitted.getHeight()));
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
            // [G2.5] 下发某页 CropBox 尺寸(PDF 点), 供 tap 坐标归一化
            case "setPageSize":
                setPageSize(methodCall, result);
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

    /**
     * [G2.5] 记录某页 CropBox 尺寸(PDF 点), 供 {@link #dispatchTap} 归一化坐标。
     *
     * <p>入参 {@code page} / {@code width} / {@code height}; 尺寸非正则视为撤销该页记录。
     */
    private void setPageSize(MethodCall call, Result result) {
        Integer page = call.argument("page");
        Double width = call.argument("width");
        Double height = call.argument("height");
        if (page == null) {
            result.success(false);
            return;
        }
        if (width == null || height == null || width <= 0 || height <= 0) {
            pointSizes.remove(page);
        } else {
            pointSizes.put(page, new SizeF(width.floatValue(), height.floatValue()));
        }
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
