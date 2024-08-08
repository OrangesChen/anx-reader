import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_style.dart';
import 'package:anx_reader/models/read_theme.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:anx_reader/utils/coordinates_to_part.dart';
import 'package:anx_reader/utils/get_base_path.dart';
import 'package:anx_reader/utils/js/convert_dart_color_to_js.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/widgets/context_menu.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/diagram.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/types_and_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class EpubPlayer extends StatefulWidget {
  final String content;
  final Book book;
  final Function showOrHideAppBarAndBottomBar;

  const EpubPlayer(
      {super.key,
      required this.content,
      required this.showOrHideAppBarAndBottomBar,
      required this.book});

  @override
  State<EpubPlayer> createState() => EpubPlayerState();
}

class EpubPlayerState extends State<EpubPlayer> {
  late InAppWebViewController webViewController;
  double progress = 0.0;
  int chapterCurrentPage = 0;
  int chapterTotalPage = 0;
  String chapterTitle = '';
  String chapterHref = '';
  late ContextMenu contextMenu;
  OverlayEntry? contextMenuEntry;

  Future<String> onReadingLocation() async {
    String currentCfi = '';
    webViewController.addJavaScriptHandler(
        handlerName: 'onReadingLocation',
        callback: (args) {
          currentCfi = args[0];
        });
    await webViewController.evaluateJavascript(source: '''
      var currentLocation = rendition.currentLocation();
      var currentCfi = currentLocation.start.cfi;
      window.flutter_inappwebview.callHandler('onReadingLocation', currentCfi);
      ''');
    return currentCfi;
  }

  void goTo(String str) {
    webViewController.evaluateJavascript(source: '''
      rendition.display('$str');
      ''');
  }

  Future<String> getToc() async {
    String toc = '';
    webViewController.addJavaScriptHandler(
        handlerName: 'getToc',
        callback: (args) {
          toc = args[0];
        });
    await webViewController.evaluateJavascript(source: '''
     getToc = function() {
       let toc = book.navigation.toc;
     
       function removeSuffix(obj) {
         if (obj.href && obj.href.includes('#')) {
           obj.href = obj.href.split('#')[0];
         }
         if (obj.subitems) {
           obj.subitems.forEach(removeSuffix);
         }
       }
     
       toc = JSON.parse(JSON.stringify(toc));
     
       toc.forEach(removeSuffix);
     
       toc = JSON.stringify(toc);
       window.flutter_inappwebview.callHandler('getToc', toc);
     }
          getToc();
      ''');
    AnxLog.info('BookPlayer: $toc');
    return toc;
  }

  void progressSetter() {
    webViewController.addJavaScriptHandler(
        handlerName: 'getCurrentInfo',
        callback: (args) {
          Map<String, dynamic> currentInfo = args[0];
          if (currentInfo['progress'] == null) {
            return;
          }
          progress = (currentInfo['progress'] as num).toDouble();
          chapterCurrentPage = currentInfo['chapterCurrentPage'];
          chapterTotalPage = currentInfo['chapterTotalPage'];
          chapterTitle = currentInfo['chapterTitle'];
          chapterHref = currentInfo['chapterHref'];
        });

    webViewController.addJavaScriptHandler(
        handlerName: 'getStyle',
        callback: (args) async {
          final Map<String, dynamic> bookStyle = {
            'fontSize': 1.2,
            'spacing': '1.5',
            'fontColor': '#66ccff',
            'backgroundColor': '#ffffff',
            'topMargin': 100,
            'bottomMargin': 100,
            'sideMargin': 5,
            'justify': true,
            'hyphenate': true,
            'scroll': false,
            'animated': true
          };

          return jsonEncode(bookStyle);
        });
  }

  void clickHandlers() {
    // window.flutter_inappwebview.callHandler('onTap', { x: x, y: y });
    webViewController.addJavaScriptHandler(
        handlerName: 'onTap',
        callback: (args) {
          if (contextMenuEntry != null) {
            removeOverlay();
            return;
          }
          Map<String, dynamic> coordinates = args[0];
          double x = coordinates['x'];
          double y = coordinates['y'];
          onViewerTap(x, y);
        });

    // window.flutter_inappwebview.callHandler('onSelected', { left: left, right: right, top: top, bottom: bottom, cfiRange: selectedCfiRange, text: selectedText });
    webViewController.addJavaScriptHandler(
        handlerName: 'onSelected',
        callback: (args) async {
          Map<String, dynamic> coordinates = args[0];
          final left = coordinates['left'];
          // double right = coordinates['right'];
          final top = coordinates['top'];
          final bottom = coordinates['bottom'];
          final annoCfi = coordinates['cfiRange'];
          if (coordinates['text'] == '') {
            return;
          }
          final annoContent = coordinates['text'];
          int? annoId = coordinates['annoId'];

          final screenSize = MediaQuery.of(context).size;

          final actualLeft = left * screenSize.width;
          final actualTop = top * screenSize.height;
          final actualBottom = bottom * screenSize.height;

          showContextMenu(
            context,
            actualLeft,
            actualTop,
            actualBottom,
            annoContent,
            annoCfi,
            annoId,
          );
        });
    // webViewController.addJavaScriptHandler(
    //     handlerName: 'getAllAnnotations',
    //     callback: (args) async {
    //       List<BookNote> annotations =
    //           await selectBookNotesByBookId(widget.bookId);
    //
    //       List<String> annotationsJson = annotations
    //           .map((annotation) => jsonEncode(annotation.toMap()))
    //           .toList();
    //
    //       for (String annotationJson in annotationsJson) {
    //         webViewController.evaluateJavascript(
    //             source: 'addABookNote($annotationJson);');
    //       }
    //     });

    webViewController.addJavaScriptHandler(
        handlerName: 'showMenu',
        callback: (args) async {
          removeOverlay();
          widget.showOrHideAppBarAndBottomBar(true);
        });
  }

  void renderNote(BookNote bookNote) {
    webViewController.evaluateJavascript(source: '''
      addABookNote(${jsonEncode(bookNote.toMap())});
      ''');
  }

  void onViewerTap(double x, double y) {
    int part = coordinatesToPart(x, y);
    int currentPageTurningType = Prefs().pageTurningType;
    List<PageTurningType> pageTurningType =
        pageTurningTypes[currentPageTurningType];
    switch (pageTurningType[part]) {
      case PageTurningType.prev:
        prevPage();
        break;
      case PageTurningType.next:
        nextPage();
        break;
      case PageTurningType.menu:
        widget.showOrHideAppBarAndBottomBar(true);
        break;
    }

    readingPageKey.currentState!.setAwakeTimer(Prefs().awakeTime);
  }

  void removeOverlay() {
    if (contextMenuEntry == null || contextMenuEntry?.mounted == false) return;
    contextMenuEntry?.remove();
    contextMenuEntry = null;
  }

  //////////////// NEW CODE /////////////////////////////////////////////////////////////////////////
  String cfi = '';
  double percentage = 0.0;

  void prevPage() {
    webViewController.evaluateJavascript(source: 'prevPage()');
  }

  void nextPage() {
    webViewController.evaluateJavascript(source: 'nextPage()');
  }

  void onClick(Map<String, dynamic> location) {
    final x = location['x'];
    final y = location['y'];
    print('x: $x, y: $y');
    final part = coordinatesToPart(x, y);
    final currentPageTurningType = Prefs().pageTurningType;
    final pageTurningType = pageTurningTypes[currentPageTurningType];
    switch (pageTurningType[part]) {
      case PageTurningType.prev:
        prevPage();
        break;
      case PageTurningType.next:
        nextPage();
        break;
      case PageTurningType.menu:
        widget.showOrHideAppBarAndBottomBar(true);
        break;
    }
  }

  void onLoadStart(InAppWebViewController controller) {
    ReadTheme readTheme = Prefs().readTheme;
    BookStyle bookStyle = Prefs().bookStyle;
    String backgroundColor = convertDartColorToJs(readTheme.backgroundColor);
    String textColor = convertDartColorToJs(readTheme.textColor);
    print('fontsize' + bookStyle.fontSize.toString());
    print('topMargin' + bookStyle.topMargin.toString());
    print('sideMargin' + bookStyle.sideMargin.toString());
    print('lineHeight' + bookStyle.lineHeight.toString());
    print('letterSpacing' + bookStyle.letterSpacing.toString());

    controller.evaluateJavascript(source: '''
      let url = 'http://localhost:${Server().port}/book/${getBasePath(widget.book.filePath)}';
      let cfi = '${widget.book.lastReadPosition}';
      console.log('BookPlayer:' + cfi);
      let style = {
          fontSize: ${bookStyle.fontSize},
          letterSpacing: ${bookStyle.letterSpacing},
          spacing: ${bookStyle.lineHeight},
          paragraphSpacing: ${bookStyle.paragraphSpacing},
          fontColor: '#$textColor',
          backgroundColor: '#$backgroundColor',
          topMargin: ${bookStyle.topMargin},
          bottomMargin: ${bookStyle.bottomMargin},
          sideMargin: ${bookStyle.sideMargin},
          justify: true,
          hyphenate: true,
          scroll: false,
          animated: true
      }
  ''');
  }

  void setHandler(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
        handlerName: 'onRelocated',
        callback: (args) {
          Map<String, dynamic> location = args[0];
          cfi = location['cfi'];
          percentage = location['percentage'];
        });
    controller.addJavaScriptHandler(
        handlerName: 'onClick',
        callback: (args) {
          Map<String, dynamic> location = args[0];
          onClick(location);
        });
  }

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    // progressSetter();
    // clickHandlers();
    setHandler(controller);
  }

  @override
  void initState() {
    super.initState();
    contextMenu = ContextMenu(
      settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
      onCreateContextMenu: (hitTestResult) async {
        webViewController.evaluateJavascript(source: "selectEnd()");
      },
      onHideContextMenu: () {
        removeOverlay();
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    super.dispose();
    InAppWebViewController.clearAllCache();
    Book book = widget.book;
    book.lastReadPosition = cfi;
    book.readingPercentage = percentage;
    updateBook(book);
    removeOverlay();
  }

  String indexHtmlPath = "localhost:${Server().port}/foliate-js/index.html";
  InAppWebViewSettings initialSettings = InAppWebViewSettings(
    supportZoom: false,
    transparentBackground: true,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(indexHtmlPath)),
            onLoadStart: (controller, url) => onLoadStart(controller),
            initialSettings: initialSettings,
            contextMenu: contextMenu,
            onWebViewCreated: (controller) => onWebViewCreated(controller),
            onConsoleMessage: (controller, consoleMessage) {
              if (consoleMessage.messageLevel == ConsoleMessageLevel.LOG) {
                AnxLog.info('Webview: ${consoleMessage.message}');
              } else if (consoleMessage.messageLevel ==
                  ConsoleMessageLevel.WARNING) {
                AnxLog.warning('Webview: ${consoleMessage.message}');
              } else if (consoleMessage.messageLevel ==
                  ConsoleMessageLevel.ERROR) {
                AnxLog.severe('Webview: ${consoleMessage.message}');
              }
            },
          ),
        ],
      ),
    );
  }

  void prevChapter() {
    webViewController.evaluateJavascript(source: '''
      prevChapter = function() {
        let toc = book.navigation.toc;
        let href = rendition.currentLocation().start.href;
        let chapter = toc.filter(chapter => chapter.href === href)[0];
        let index = toc.indexOf(chapter);
        if (index > 0) {
          rendition.display(toc[index - 1].href);
        }
      }
      prevChapter();
      refreshProgress();
      ''');
  }

  void nextChapter() {
    webViewController.evaluateJavascript(source: '''
    nextChapter = function() {
        let toc = book.navigation.toc;
        let href = rendition.currentLocation().start.href;
        let chapter = toc.filter(chapter => chapter.href === href)[0];
        let index = toc.indexOf(chapter);
        if (index < toc.length - 1) {
          rendition.display(toc[index + 1].href);
        }
      }
      nextChapter();
      refreshProgress();
      ''');
  }

  Future<void> goToPercentage(double value) async {
    await webViewController.evaluateJavascript(source: '''
      goToPercentage = function(value) {
        let location = book.locations.cfiFromPercentage(value);
        rendition.display(location);
      }
      goToPercentage($value);
      refreshProgress();
      
      ''');
  }

  void changeTheme(ReadTheme readTheme) {
    String backgroundColor = convertDartColorToJs(readTheme.backgroundColor);
    String textColor = convertDartColorToJs(readTheme.textColor);

    webViewController.evaluateJavascript(source: '''
      changeStyle({
        backgroundColor: '#$backgroundColor',
        fontColor: '#$textColor',
      })
      ''');
  }

  void changeStyle(BookStyle bookStyle) {
    webViewController.evaluateJavascript(source: '''
      changeStyle({
        fontSize: ${bookStyle.fontSize},
        spacing: '${bookStyle.lineHeight}',
        paragraphSpacing: ${bookStyle.paragraphSpacing},
        topMargin: ${bookStyle.topMargin},
        bottomMargin: ${bookStyle.bottomMargin},
        sideMargin: ${bookStyle.sideMargin},
        letterSpacing: ${bookStyle.letterSpacing},
      })
    ''');
  }
}
