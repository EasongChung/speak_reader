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
import android.content.Intent;
import android.net.Uri;

import com.github.barteksc.pdfviewer.PDFView;
import com.github.barteksc.pdfviewer.link.LinkHandler;
import com.github.barteksc.pdfviewer.model.LinkTapEvent;

import io.flutter.plugin.common.MethodChannel;

/**
 * [G2] 本文件 vendoring 自 flutter_pdfview 1.4.4 (MIT, Copyright (c) 2019 endigo),
 * 内容与上游一致, 未作修改。上游: https://github.com/endigo/flutter_pdfview
 */
public class PDFLinkHandler implements LinkHandler {
    PDFView pdfView;
    Context context;
    MethodChannel methodChannel;
    boolean preventLinkNavigation;

    public PDFLinkHandler(Context context, PDFView pdfView, MethodChannel methodChannel, boolean preventLinkNavigation) {
        this.context = context;
        this.pdfView = pdfView;
        this.methodChannel = methodChannel;
        this.preventLinkNavigation = preventLinkNavigation;
    }

    @Override
    public void handleLinkEvent(LinkTapEvent event) {
        String uri = event.getLink().getUri();
        Integer page = event.getLink().getDestPageIdx();
        if (uri != null && !uri.isEmpty()) {
            handleUri(uri);
        } else if (page != null) {
            handlePage(page);
        }
    }

    private void handleUri(String uri) {
        // If the property is true just pass the link back to flutter
        if (!this.preventLinkNavigation) {
            Uri parsedUri = Uri.parse(uri);
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setData(parsedUri);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK);

            if (intent.resolveActivity(context.getPackageManager()) != null) {
                context.startActivity(intent, null);
            }
        }
        this.onLinkHandler(uri);
    }

    private void handlePage(int page) {
        pdfView.jumpTo(page);
    }

    // Notify Flutter of Link request
    private void onLinkHandler(String uri) {
        this.methodChannel.invokeMethod("onLinkHandler", uri);
    }

    public void setPreventLinkNavigation(boolean value){
        this.preventLinkNavigation = value;
    }
}
