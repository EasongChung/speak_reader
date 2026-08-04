package com.example.speak_reader

import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition

/**
 * [G1] 单个字符的坐标框。
 *
 * 坐标系为 PDFBox「方向校正后的显示空间」: 原点在页面 CropBox 左上角,
 * x 向右为正、y 向下为正, 单位是 PDF 点(1/72 英寸)。
 *
 * 注意 [y] 取自 `TextPosition.getYDirAdj()`, 是字形的**下沿**(基线偏下),
 * 因此矩形上沿应按 `y - h` 计算。该假设由 Gate 1 的描框校验图实测确认。
 */
data class CharBox(
    val ch: String,
    val x: Float,
    val y: Float,
    val w: Float,
    val h: Float,
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
            boxes.add(
                CharBox(
                    ch = unicode,
                    x = p.xDirAdj,
                    y = p.yDirAdj,
                    w = p.widthDirAdj,
                    h = p.heightDir,
                )
            )
        }
        super.writeString(text, textPositions)
    }
}
