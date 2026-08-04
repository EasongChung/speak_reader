package com.example.speak_reader

import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import kotlin.math.abs

/**
 * [G1] 单个字符的坐标与字体度量。
 *
 * 坐标系为 PDFBox「方向校正后的显示空间」: 原点在页面 CropBox 左上角,
 * x 向右为正、y 向下为正, 单位是 PDF 点(1/72 英寸)。
 *
 * ## Gate 1 第一轮实测结论(960x540 页面, crop=(0,0), rot=0, 623 字符)
 *
 * - [x] / [w] 完全正确, 中英文均严丝合缝;
 * - [y] 是**基线**(baseline)在 top-down 坐标下的位置, 不是字形下沿;
 * - [h] 取自 `TextPosition.getHeightDir()`, PDFBox 内部按「字体 bbox 高的一半,
 *   或 capHeight 取小者」计算, 实测**只适用于拉丁大写字母**(MANTIS 完美贴合),
 *   中文字身高约 1.0 em(基线上 0.88 / 基线下 0.12)会被上下各截掉一截。
 *
 * 因此正式的竖直范围不再使用 [h], 改由字体度量 [asc] / [desc] 推导:
 * `top = y - asc`, `bottom = y - desc`([desc] 为负值)。
 */
data class CharBox(
    val ch: String,
    val x: Float,
    val y: Float,
    val w: Float,
    /** `getHeightDir()`, 仅保留作对照(方案 A), 不用于正式排版 */
    val h: Float,
    /** 有效字号(显示点), 取自文本渲染矩阵的竖直缩放 */
    val fs: Float,
    /** 字体 ascent, 已按 [fs] 缩放为显示点(正值) */
    val asc: Float,
    /** 字体 descent, 已按 [fs] 缩放为显示点(负值) */
    val desc: Float,
)

/**
 * [G1] 收集字符级坐标的 [PDFTextStripper] 子类。
 *
 * PDFBox 在 `writeString` 回调里给出与文本一一对应的 [TextPosition] 列表,
 * 逐个取方向校正后的坐标即可得到字符框, 无需任何 OCR。
 *
 * `sortByPosition = true` 保证回调顺序即阅读顺序(供 Gate 3 合成句子框使用)。
 */
class CharBoxStripper : PDFTextStripper() {

    val boxes = mutableListOf<CharBox>()

    init {
        sortByPosition = true
    }

    override fun writeString(text: String, textPositions: List<TextPosition>) {
        for (p in textPositions) {
            val unicode = p.unicode
            // 合字(如 ﬁ)会展开成多字符; 空 unicode 的定位符直接跳过
            if (unicode.isNullOrEmpty()) continue

            // textMatrix 是含字号的文本渲染矩阵, 其竖直缩放即有效字号(显示点);
            // 竖直翻转的文本会得到负值, 取绝对值。不用 fontSizeInPt: 该值在
            // PDFBox 内部经过取整, 10.5pt 这类非整数字号会丢精度。
            val fs = abs(p.textMatrix.scalingFactorY)

            // 字体度量单位为 1/1000 em; 描述符可能缺失(标准 14 字体)或填错值
            val descriptor = p.font.fontDescriptor
            var ascRatio = (descriptor?.ascent ?: 0f) / 1000f
            var descRatio = (descriptor?.descent ?: 0f) / 1000f
            // 异常值回退到 CJK 通用 em 框比例, 避免画出离谱的框
            if (ascRatio <= 0f || ascRatio > 1.5f) ascRatio = 0.88f
            if (descRatio >= 0f || descRatio < -0.6f) descRatio = -0.12f

            boxes.add(
                CharBox(
                    ch = unicode,
                    x = p.xDirAdj,
                    y = p.yDirAdj,
                    w = p.widthDirAdj,
                    h = p.heightDir,
                    fs = fs,
                    asc = ascRatio * fs,
                    desc = descRatio * fs,
                )
            )
        }
        super.writeString(text, textPositions)
    }
}
