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
 * ## Gate 1 实测定论(960x540 页面, crop=(0,0), rot=0, 623 字符, 已通过)
 *
 * 样例首字符 `案`: `y=40.15 h=11.01 fs=21.95 asc=18.86 desc=-3.16`
 *
 * | 量 | 折算 | 结论 |
 * |---|---|---|
 * | [x] / [w] | — | 直接可用, 中英文均严丝合缝 |
 * | [y] | — | **基线**(top-down), 不是字形下沿 |
 * | [h] | 11.01/21.95 = 0.50 em | `getHeightDir()` 恰为 em 的一半, 中文截掉一半 |
 * | [asc]/[desc] | 0.859 / -0.144 em | 该字体声明值, 合计 1.003 em |
 *
 * 竖直范围最终采用**固定 em 框**([topEm] / [bottomEm]): 与字体度量方案在
 * 本样本仅差 0.003 em, 但实测整页对照 em 框明显更齐平——原因是页面混排的
 * 拉丁与粗体字体 `asc`/`desc` 声明值偏大且彼此不一致(`hhea` 与 `OS/2`
 * 两套度量常年不同), 导致字体度量方案框高随字体跳变。恒定 1.0 em 对
 * Gate 3 按竖直区间分行归组更稳。
 *
 * [asc] / [desc] 予以保留: 供 Gate 3 遇到异常字体时回退比对, 并作为
 * 本结论的实测留档。
 */
data class CharBox(
    val ch: String,
    val x: Float,
    val y: Float,
    val w: Float,
    /** `getHeightDir()`, 实测为 0.5 em, 仅保留作对照, 不用于排版 */
    val h: Float,
    /** 有效字号(显示点), 取自文本渲染矩阵的竖直缩放 */
    val fs: Float,
    /** 字体 ascent, 已按 [fs] 缩放为显示点(正值) */
    val asc: Float,
    /** 字体 descent, 已按 [fs] 缩放为显示点(负值) */
    val desc: Float,
) {
    /** 字形上沿: 基线上方 0.88 em(Gate 1 实测定论) */
    val topEm: Float get() = y - ASCENT_EM * fs

    /** 字形下沿: 基线下方 0.12 em(Gate 1 实测定论) */
    val bottomEm: Float get() = y + DESCENT_EM * fs

    companion object {
        /** em 框上沿比例, 覆盖 CJK 字身与拉丁大写高 */
        const val ASCENT_EM = 0.88f

        /** em 框下沿比例, 覆盖拉丁小写降部与 CJK 字身下缘 */
        const val DESCENT_EM = 0.12f
    }
}

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
