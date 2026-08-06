/*
 * Copyright 2016 Bartosz Schiller
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.github.barteksc.pdfviewer;

import com.shockwave.pdfium.util.SizeF;

/**
 * [G2] AndroidPdfViewer 坐标换算桥接。
 *
 * <p>本类**必须**位于 {@code com.github.barteksc.pdfviewer} 包下: {@link PDFView#pdfFile}
 * 是包内可见字段, 外部包无法访问, 而页面偏移换算只能经由 {@link PdfFile} 取得。
 * 除此之外本类不含任何上游代码, 仅做只读转发。
 *
 * <h3>为什么需要它(上游 bug)</h3>
 * 上游 {@code PDFView.drawWithListener} 在竖向滚动时把次轴偏移写死为 0:
 * <pre>
 *     if (swipeVertical) { translateX = 0; translateY = getPageOffset(...); }
 * </pre>
 * 而真正绘制页面的 {@code drawPart} 用的却是水平居中偏移
 * {@code toCurrentScale(maxWidth - size.getWidth()) / 2}, 即
 * {@link PdfFile#getSecondaryPageOffset}。两者不一致——各页等宽时差值恰为 0,
 * 所以上游一直没暴露; 一旦文档页宽不一, {@code onLayerDrawn} 的画布原点就会
 * 与页面实际位置**水平错开**。
 *
 * <p>因此 OnDrawListener 里不能直接信任画布原点, 需用 {@link #getSecondaryPageOffset}
 * 补偿。而 tap 换算则照抄上游 {@code DragPinchManager#onSingleTapConfirmed} 的配方
 * ({@link #getPageOffset} / {@link #getPageAtOffset}), 使**画框与命中共用同一套换算**,
 * 从根上杜绝两者对不齐。
 */
public final class PdfViewGeometryBridge {

    private PdfViewGeometryBridge() {
    }

    /** 文档是否已加载完成; 未加载时其余方法均不可调用 */
    public static boolean isReady(PDFView pdfView) {
        return pdfView != null && pdfView.pdfFile != null;
    }

    /**
     * 次轴偏移(竖向滚动时为 X, 横向为 Y), **已含 zoom**。
     * 用于修正上游 drawWithListener 写死 0 的偏差。
     */
    public static float getSecondaryPageOffset(PDFView pdfView, int page) {
        if (!isReady(pdfView)) {
            return 0f;
        }
        return pdfView.pdfFile.getSecondaryPageOffset(page, pdfView.getZoom());
    }

    /** 主轴偏移(竖向滚动时为 Y, 横向为 X), **已含 zoom** */
    public static float getPageOffset(PDFView pdfView, int page) {
        if (!isReady(pdfView)) {
            return 0f;
        }
        return pdfView.pdfFile.getPageOffset(page, pdfView.getZoom());
    }

    /** 主轴偏移量落在第几页; 入参为已减去 currentOffset 的文档坐标 */
    public static int getPageAtOffset(PDFView pdfView, float offset) {
        if (!isReady(pdfView)) {
            return 0;
        }
        return pdfView.pdfFile.getPageAtOffset(offset, pdfView.getZoom());
    }

    /**
     * 指定页的适配尺寸(FitPolicy 缩放后的像素, 非 PDF 原始点)。
     *
     * <p><strong>注意：</strong>此方法返回的是上游 {@link PdfFile#getPageSize} 的
     * {@code Scaled page sizes}（FitPolicy 适配后像素），<strong>不是</strong>
     * PDF 原始点尺寸。真实 PDF 点尺寸位于 {@code PdfFile.originalPageSizes}（私有字段）。
     *
     * <p>这是 G2.5.1 缺陷源头：此注释最初错写为"原始尺寸(未缩放, 单位与 PDF 点一致)"，
     * 导致坐标换算时误将适配像素当作 PDF 点使用，造成「命中对、画框错」。
     */
    public static SizeF getPageSize(PDFView pdfView, int page) {
        if (!isReady(pdfView)) {
            return new SizeF(0f, 0f);
        }
        return pdfView.pdfFile.getPageSize(page);
    }
}
