// MIT License
//
// Copyright (c) 2019 endigo
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.

/// [G2] 本文件 vendoring 自 flutter_pdfview 1.4.4 (MIT, Copyright (c) 2019 endigo)。
/// 上游: https://github.com/endigo/flutter_pdfview
///
/// 本项目改动(其余部分与上游一致):
/// 1. ViewType 改为 `speak_reader/pdfview`, 与上游注册名区隔;
/// 2. 新增 [PDFView.onTap] 回调, 回传页面坐标(PDF 点), 供点击朗读定位字符;
/// 3. 新增 [PDFViewController.setHighlights] / [PDFViewController.clearHighlights];
/// 4. 移除 iOS 分支: 本项目仅支持 Android(arm64-v8a), 原生侧未 vendoring iOS 实现。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

typedef PDFViewCreatedCallback = void Function(PDFViewController controller);
typedef RenderCallback = void Function(int? pages);
typedef PageChangedCallback = void Function(int? page, int? total);
typedef ErrorCallback = void Function(dynamic error);
typedef PageErrorCallback = void Function(int? page, dynamic error);
typedef LinkHandlerCallback = void Function(String? uri);

/// [G2] 点击回调: 回传点击处的页码与**页面坐标**(PDF 点, 原点在 CropBox 左上角)。
typedef PdfTapCallback = void Function(PdfTapDetails details);

/// [G2] 平台视图注册名。移除 pub 依赖后由 MainActivity 手工注册,
/// 改名以免与任何残留的上游注册撞名。
const String _kViewType = 'speak_reader/pdfview';

/// [G2] 一次点击的位置信息。
///
/// [x] / [y] 与 PDFBox 的 `extractTextPositions` 输出同一坐标系(页面点,
/// 原点在 CropBox 左上角, y 向下), 可直接与字符框做命中比对。
@immutable
class PdfTapDetails {
  const PdfTapDetails({
    required this.page,
    required this.x,
    required this.y,
    required this.pageWidth,
    required this.pageHeight,
  });

  /// 页码, 从 0 开始
  final int page;

  /// 页内 x(页面点)
  final double x;

  /// 页内 y(页面点, 向下为正)
  final double y;

  /// 该页宽(页面点)
  final double pageWidth;

  /// 该页高(页面点)
  final double pageHeight;

  @override
  String toString() => 'PdfTapDetails(page: $page, x: $x, y: $y, '
      'pageWidth: $pageWidth, pageHeight: $pageHeight)';
}

/// 保持上游的全大写枚举名: [_PDFViewSettings.toMap] 把它 `toString()` 后经
/// MethodChannel 下发, 原生侧 `FlutterPDFView.getFitPolicy` 按
/// `"FitPolicy.WIDTH"` 字面量匹配, 改名会静默破坏适配策略。
// ignore: constant_identifier_names
enum FitPolicy { WIDTH, HEIGHT, BOTH }

class PDFView extends StatefulWidget {
  const PDFView({
    super.key,
    this.filePath,
    this.pdfData,
    this.onViewCreated,
    this.onRender,
    this.onPageChanged,
    this.onError,
    this.onPageError,
    this.onLinkHandler,
    this.onTap,
    this.gestureRecognizers,
    this.enableSwipe = true,
    this.swipeHorizontal = false,
    this.password,
    this.nightMode = false,
    this.autoSpacing = true,
    this.pageFling = true,
    this.pageSnap = true,
    this.enableAntialiasing = true,
    this.useBestQuality = true,
    this.enableRenderDuringScale = true,
    this.thumbnailRatio = 0.8,
    this.defaultPage = 0,
    this.fitPolicy = FitPolicy.WIDTH,
    this.preventLinkNavigation = false,
    this.backgroundColor,
  }) : assert(filePath != null || pdfData != null);

  /// If not null invoked once the PDFView is created.
  final PDFViewCreatedCallback? onViewCreated;

  /// Return PDF page count as a parameter
  final RenderCallback? onRender;

  /// Return current page and page count as a parameter
  final PageChangedCallback? onPageChanged;

  /// Invokes on error that handled on native code
  final ErrorCallback? onError;

  /// Invokes on page cannot be rendered or something happens
  final PageErrorCallback? onPageError;

  /// Used with preventLinkNavigation=true. It's helpful to customize link navigation
  final LinkHandlerCallback? onLinkHandler;

  /// [G2] 单击回调, 回传页面坐标
  final PdfTapCallback? onTap;

  /// Which gestures should be consumed by the pdf view.
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;

  /// The initial URL to load.
  final String? filePath;

  /// The binary data of a PDF document
  final Uint8List? pdfData;

  /// Indicates whether or not the user can swipe to change pages in the PDF document.
  final bool enableSwipe;

  /// Indicates whether or not the user can swipe horizontally to change pages.
  final bool swipeHorizontal;

  /// Represents the password for a password-protected PDF document.
  final String? password;

  /// Indicates whether or not the PDF viewer is in night mode.
  final bool nightMode;

  /// Indicates whether or not the PDF viewer automatically adds spacing between pages.
  final bool autoSpacing;

  /// Indicates whether or not the user can "fling" pages in the PDF document.
  final bool pageFling;

  /// Indicates whether or not the viewer snaps to a page after the user has scrolled to it.
  final bool pageSnap;

  /// Controls whether the PDF renderer uses anti-aliasing (Android only).
  final bool enableAntialiasing;

  /// Improves render quality at the cost of performance (Android only).
  final bool useBestQuality;

  /// Renders during scale gestures for smoother zooming (Android only).
  final bool enableRenderDuringScale;

  /// Thumbnail ratio used by AndroidPdfViewer (Android only).
  final double? thumbnailRatio;

  /// Represents the default page to display when the PDF document is loaded.
  final int defaultPage;

  /// FitPolicy that determines how the PDF pages are fit to the screen.
  final FitPolicy fitPolicy;

  /// Indicates whether or not clicking on links in the PDF document will open the link.
  final bool preventLinkNavigation;

  /// Use to change the background color.
  final Color? backgroundColor;

  @override
  State<PDFView> createState() => _PDFViewState();
}

class _PDFViewState extends State<PDFView> {
  final Completer<PDFViewController> _controller =
      Completer<PDFViewController>();

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return PlatformViewLink(
        viewType: _kViewType,
        surfaceFactory:
            (BuildContext context, PlatformViewController controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: widget.gestureRecognizers ??
                const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          );
        },
        onCreatePlatformView: (PlatformViewCreationParams params) {
          return PlatformViewsService.initSurfaceAndroidView(
            id: params.id,
            viewType: _kViewType,
            layoutDirection: TextDirection.rtl,
            creationParams: _CreationParams.fromWidget(widget).toMap(),
            creationParamsCodec: const StandardMessageCodec(),
          )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..addOnPlatformViewCreatedListener(_onPlatformViewCreated)
            ..create();
        },
      );
    }
    // [G2] 本项目仅 Android: 原生侧未 vendoring iOS 实现
    return Text('$defaultTargetPlatform is not supported by this PDF viewer');
  }

  void _onPlatformViewCreated(int id) {
    final PDFViewController controller = PDFViewController._(id, widget);
    _controller.complete(controller);
    widget.onViewCreated?.call(controller);
  }

  @override
  void didUpdateWidget(PDFView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.future.then(
        (PDFViewController controller) => controller._updateWidget(widget));
  }

  @override
  void dispose() {
    _controller.future
        .then((PDFViewController controller) => controller.dispose());
    super.dispose();
  }
}

class _CreationParams {
  _CreationParams({this.filePath, this.pdfData, this.settings});

  static _CreationParams fromWidget(PDFView widget) {
    return _CreationParams(
      filePath: widget.filePath,
      pdfData: widget.pdfData,
      settings: _PDFViewSettings.fromWidget(widget),
    );
  }

  final String? filePath;
  final Uint8List? pdfData;
  final _PDFViewSettings? settings;

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> params = <String, dynamic>{
      'filePath': filePath,
      'pdfData': pdfData,
    };
    params.addAll(settings!.toMap());
    return params;
  }
}

class _PDFViewSettings {
  _PDFViewSettings({
    this.enableSwipe,
    this.swipeHorizontal,
    this.password,
    this.nightMode,
    this.autoSpacing,
    this.pageFling,
    this.pageSnap,
    this.enableAntialiasing,
    this.useBestQuality,
    this.enableRenderDuringScale,
    this.thumbnailRatio,
    this.defaultPage,
    this.fitPolicy,
    this.preventLinkNavigation,
    this.backgroundColor,
  });

  static _PDFViewSettings fromWidget(PDFView widget) {
    return _PDFViewSettings(
      enableSwipe: widget.enableSwipe,
      swipeHorizontal: widget.swipeHorizontal,
      password: widget.password,
      nightMode: widget.nightMode,
      autoSpacing: widget.autoSpacing,
      pageFling: widget.pageFling,
      pageSnap: widget.pageSnap,
      enableAntialiasing: widget.enableAntialiasing,
      useBestQuality: widget.useBestQuality,
      enableRenderDuringScale: widget.enableRenderDuringScale,
      thumbnailRatio: widget.thumbnailRatio,
      defaultPage: widget.defaultPage,
      fitPolicy: widget.fitPolicy,
      preventLinkNavigation: widget.preventLinkNavigation,
      backgroundColor: widget.backgroundColor,
    );
  }

  final bool? enableSwipe;
  final bool? swipeHorizontal;
  final String? password;
  final bool? nightMode;
  final bool? autoSpacing;
  final bool? pageFling;
  final bool? pageSnap;
  final bool? enableAntialiasing;
  final bool? useBestQuality;
  final bool? enableRenderDuringScale;
  final double? thumbnailRatio;
  final int? defaultPage;
  final FitPolicy? fitPolicy;
  final bool? preventLinkNavigation;
  final Color? backgroundColor;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'enableSwipe': enableSwipe,
      'swipeHorizontal': swipeHorizontal,
      'password': password,
      'nightMode': nightMode,
      'autoSpacing': autoSpacing,
      'pageFling': pageFling,
      'pageSnap': pageSnap,
      'enableAntialiasing': enableAntialiasing,
      'useBestQuality': useBestQuality,
      'enableRenderDuringScale': enableRenderDuringScale,
      'thumbnailRatio': thumbnailRatio,
      'defaultPage': defaultPage,
      'fitPolicy': fitPolicy.toString(),
      'preventLinkNavigation': preventLinkNavigation,
      // ignore: deprecated_member_use
      'backgroundColor': backgroundColor?.value,
    };
  }

  Map<String, dynamic> updatesMap(_PDFViewSettings newSettings) {
    final Map<String, dynamic> updates = <String, dynamic>{};
    if (enableSwipe != newSettings.enableSwipe) {
      updates['enableSwipe'] = newSettings.enableSwipe;
    }
    if (pageFling != newSettings.pageFling) {
      updates['pageFling'] = newSettings.pageFling;
    }
    if (pageSnap != newSettings.pageSnap) {
      updates['pageSnap'] = newSettings.pageSnap;
    }
    if (preventLinkNavigation != newSettings.preventLinkNavigation) {
      updates['preventLinkNavigation'] = newSettings.preventLinkNavigation;
    }
    return updates;
  }
}

class PDFViewController {
  PDFViewController._(int id, PDFView widget)
      : _channel = MethodChannel('plugins.endigo.io/pdfview_$id'),
        _widget = widget {
    _settings = _PDFViewSettings.fromWidget(widget);
    _channel.setMethodCallHandler(_onMethodCall);
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _widget = null;
  }

  final MethodChannel _channel;

  late _PDFViewSettings _settings;

  PDFView? _widget;

  Future<bool?> _onMethodCall(MethodCall call) async {
    final PDFView? widget = _widget;
    if (widget == null) return null;

    switch (call.method) {
      case 'onRender':
        widget.onRender?.call(call.arguments['pages']);
        return null;
      case 'onPageChanged':
        widget.onPageChanged
            ?.call(call.arguments['page'], call.arguments['total']);
        return null;
      case 'onError':
        widget.onError?.call(call.arguments['error']);
        return null;
      case 'onPageError':
        widget.onPageError
            ?.call(call.arguments['page'], call.arguments['error']);
        return null;
      case 'onLinkHandler':
        widget.onLinkHandler?.call(call.arguments);
        return null;
      // [G2] 原生侧上报的点击位置
      case 'onTap':
        final Map<Object?, Object?> a = call.arguments as Map<Object?, Object?>;
        widget.onTap?.call(PdfTapDetails(
          page: (a['page'] as num).toInt(),
          x: (a['x'] as num).toDouble(),
          y: (a['y'] as num).toDouble(),
          pageWidth: (a['pageWidth'] as num).toDouble(),
          pageHeight: (a['pageHeight'] as num).toDouble(),
        ));
        return null;
    }
    throw MissingPluginException(
        '${call.method} was invoked but has no handler');
  }

  Future<int?> getPageCount() async {
    return _channel.invokeMethod<int>('pageCount');
  }

  Future<int?> getCurrentPage() async {
    return _channel.invokeMethod<int>('currentPage');
  }

  Future<bool?> setPage(int page) async {
    return _channel
        .invokeMethod<bool>('setPage', <String, dynamic>{'page': page});
  }

  /// [G2] 在指定页绘制高亮框。
  ///
  /// [rects] 单位为页面坐标(PDF 点), 与 [PdfTapDetails] 及 PDFBox 字符框同一坐标系。
  /// 传空列表等同于清除。
  Future<void> setHighlights(int page, List<Rect> rects) async {
    await _channel.invokeMethod<bool>('setHighlights', <String, dynamic>{
      'page': page,
      'rects': rects
          .map((Rect r) => <double>[r.left, r.top, r.right, r.bottom])
          .toList(),
    });
  }

  /// [G2] 清除全部高亮框
  Future<void> clearHighlights() async {
    await _channel.invokeMethod<bool>('clearHighlights');
  }

  Future<void> _updateWidget(PDFView widget) async {
    _widget = widget;
    await _updateSettings(_PDFViewSettings.fromWidget(widget));
  }

  Future<void> _updateSettings(_PDFViewSettings setting) async {
    final Map<String, dynamic> updateMap = _settings.updatesMap(setting);
    if (updateMap.isEmpty) {
      return;
    }
    _settings = setting;
    return _channel.invokeMethod('updateSettings', updateMap);
  }
}
