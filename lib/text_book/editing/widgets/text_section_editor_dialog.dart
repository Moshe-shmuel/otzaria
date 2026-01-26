import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; // הוספת import עבור SelectedContent
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../bloc/text_book_bloc.dart';
import '../../bloc/text_book_event.dart';

import '../services/preview_renderer.dart';
import '../models/editor_settings.dart';
import 'package:otzaria/data/data_providers/file_system_data_provider.dart';
import 'package:otzaria/core/scaffold_messenger.dart';
import 'package:otzaria/widgets/confirmation_dialog.dart';
import 'markdown_toolbar.dart';
import 'editor_headers_bar.dart';

// מצבי תצוגה
enum ViewMode {
  formatted, // טקסט מעוצב (תצוגה מקדימה)
  raw, // טקסט גולמי (HTML עם tags)
  split // מצב משולב (עורך + תצוגה מקדימה)
}

/// Full-screen dialog for editing text sections with split-pane interface
///
/// Key features:
/// - No auto-save drafts - saves only when user clicks save
/// - Background rendering with debouncing for smooth typing
/// - Toolbar positioned on the right side above editor
/// - HTML tags support (not Markdown)
/// - Parallel column layout for simultaneous editing and preview
/// - Improved cursor synchronization between formatted and raw views:
///   * Cursor is displayed in formatted view at the correct position
///   * Clicking in formatted view positions cursor accurately
///   * Text selection in formatted view syncs with raw editor
///   * Arrow keys work properly in formatted view with cursor blinking
class TextSectionEditorDialog extends StatefulWidget {
  final String bookId;
  final int sectionIndex;
  final String sectionId;
  final String initialContent;
  final bool hasLinksFile;
  final bool hasDraft;
  final EditorSettings settings;
  final String? category;
  final String? fileType;

  const TextSectionEditorDialog({
    super.key,
    required this.bookId,
    required this.sectionIndex,
    required this.sectionId,
    required this.initialContent,
    required this.hasLinksFile,
    required this.hasDraft,
    required this.settings,
    this.category,
    this.fileType,
  });

  @override
  State<TextSectionEditorDialog> createState() =>
      _TextSectionEditorDialogState();
}

class _TextSectionEditorDialogState extends State<TextSectionEditorDialog> {
  late TextEditingController _textController;
  late PreviewRenderer _previewRenderer;
  Timer? _debounceTimer;

  bool _hasUnsavedChanges = false;
  String _previewContent = '';
  final List<int> _plainToOriginalMap = []; // מפה לקבלת עמדות בO(1) במקום O(n)
  final FocusNode _editorFocusNode = FocusNode();
  String? _lastSearchText; // לשמירת טקסט החיפוש האחרון עבור F3

  // מצבי תצוגה
  ViewMode _currentViewMode = ViewMode.formatted;

  // Undo functionality
  final List<String> _undoStack = [];
  final List<TextSelection> _undoSelectionStack = [];
  int _undoIndex = -1;
  bool _isUndoRedoOperation = false;

  late ScrollController _editorScrollController;
  late ScrollController _previewScrollController;
  bool _isSyncingScroll = false;
  Timer? _scrollSyncTimer; // טיימר לביטול סנכרון גלילה

  // Flag to prevent duplicate undo snapshots when programmatic changes trigger _onTextChanged
  bool _isApplyingProgrammaticChange = false;

  // Background rendering state
  bool _isRenderingInBackground = false;
  Isolate? _renderIsolate;
  ReceivePort? _receivePort;

  // Performance optimizations
  String _lastRenderedContent = '';
  Timer? _mapDebounceTimer; // debounce לבנייה של _plainToOriginalMap

  // Static variable to track if notification was shown this session
  static bool _hasShownNotification = false;

  // Cursor position for formatted view
  bool _showCursor = false;
  Timer? _cursorTimer;

  @override
  void initState() {
    super.initState();

    _textController = TextEditingController(text: widget.initialContent);
    _previewRenderer = PreviewRenderer();
    _previewContent = widget.initialContent;
    _buildPlainTextMap(widget.initialContent); // בנה את המפה בתחילה

    _editorScrollController = ScrollController();
    _previewScrollController = ScrollController();

    _editorScrollController.addListener(_syncScrollFromEditor);
    _previewScrollController.addListener(_syncScrollFromPreview);

    // Initialize undo stack with initial content
    _saveToUndoStack(widget.initialContent,
        TextSelection.collapsed(offset: widget.initialContent.length));

    // Listen to text changes
    _textController.addListener(_onTextChanged);

    // Listen to selection changes to update cursor position
    _textController.addListener(_onSelectionChanged);

    // Show first-time notification
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showFirstTimeNotification();
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _debounceTimer?.cancel();
    _mapDebounceTimer?.cancel();
    _scrollSyncTimer?.cancel(); // בטל טיימר סנכרון גלילה
    _cursorTimer?.cancel(); // בטל טיימר הסמן
    _renderIsolate?.kill();
    _receivePort?.close();
    _editorFocusNode.dispose();
    _editorScrollController.dispose();
    _previewScrollController.dispose();
    super.dispose();
  }

  void _syncScrollFromEditor() {
    if (_isSyncingScroll || !mounted) return;

    // בדוק שה-controllers מוכנים
    if (!_editorScrollController.hasClients ||
        !_previewScrollController.hasClients) {
      return;
    }

    _isSyncingScroll = true;

    final editorOffset = _editorScrollController.offset;
    final editorMaxScroll = _editorScrollController.position.maxScrollExtent;
    final previewMaxScroll = _previewScrollController.position.maxScrollExtent;

    if (editorMaxScroll > 0 && previewMaxScroll > 0) {
      final scrollFraction = editorOffset / editorMaxScroll;
      _previewScrollController.jumpTo(scrollFraction * previewMaxScroll);
    }

    // השתמש בטיימר במקום Future.delayed למניעת memory leaks
    _scrollSyncTimer?.cancel();
    _scrollSyncTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        _isSyncingScroll = false;
      }
    });
  }

  void _syncScrollFromPreview() {
    if (_isSyncingScroll || !mounted) return;

    // בדוק שה-controllers מוכנים
    if (!_previewScrollController.hasClients ||
        !_editorScrollController.hasClients) {
      return;
    }

    _isSyncingScroll = true;

    final previewOffset = _previewScrollController.offset;
    final previewMaxScroll = _previewScrollController.position.maxScrollExtent;
    final editorMaxScroll = _editorScrollController.position.maxScrollExtent;

    if (previewMaxScroll > 0 && editorMaxScroll > 0) {
      final scrollFraction = previewOffset / previewMaxScroll;
      _editorScrollController.jumpTo(scrollFraction * editorMaxScroll);
    }

    // השתמש בטיימר במקום Future.delayed למניעת memory leaks
    _scrollSyncTimer?.cancel();
    _scrollSyncTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        _isSyncingScroll = false;
      }
    });
  }

  void _renderPreviewInBackground(String content) async {
    if (_isRenderingInBackground || content == _lastRenderedContent) {
      // Skip if already rendering or content hasn't changed
      return;
    }

    setState(() {
      _isRenderingInBackground = true;
    });

    // Use HTML caching in MarkdownProcessor for better performance
    await Future.delayed(const Duration(milliseconds: 50));

    if (mounted) {
      setState(() {
        _previewContent = content;
        _lastRenderedContent = content;
        // עדכן גם את המפה בעדכון preview
        _buildPlainTextMap(content);
        _isRenderingInBackground = false;
      });
    }
  }

  void _showFirstTimeNotification() {
    // Only show once per session
    if (!mounted || _hasShownNotification) return;

    _hasShownNotification = true;

    UiSnack.showFloating(
        'שים לב: השינויים נשמרים מקומית בלבד, ובמקרה של עדכון הספרייה, השינויים ימחקו!');
  }

  void _save() {
    context.read<TextBookBloc>().add(SaveEditedSection(
          index: widget.sectionIndex,
          sectionId: widget.sectionId,
          markdown: _textController.text,
        ));

    setState(() {
      _hasUnsavedChanges = false;
    });

    // Trigger content refresh to ensure the main viewer shows updated content
    Future.delayed(const Duration(milliseconds: 100), () async {
      if (mounted) {
        try {
          // Force a content reload from file system to ensure refresh
          final dataProvider = FileSystemData.instance;
          await dataProvider.getBookText(widget.bookId);

          // Show success feedback
          UiSnack.showSuccess(UiSnack.savedSuccessfully);
        } catch (e) {
          debugPrint('Failed to verify save: $e');
          // Still show success feedback even if verification fails
          UiSnack.show(UiSnack.savedSuccessfully);
        }
      }
    });
  }

  void _saveAndClose() {
    _save();
    Navigator.of(context).pop();
  }

  void _discardChanges() async {
    if (_hasUnsavedChanges) {
      final confirmed = await showConfirmationDialog(
        context: context,
        title: 'בטל שינויים',
        content: 'האם אתה בטוח שברצונך לבטל את השינויים?',
        confirmText: 'בטל שינויים',
        isDangerous: true,
      );

      if (confirmed == true && mounted) {
        Navigator.of(context).pop();
      }
    } else {
      Navigator.of(context).pop();
    }
  }

  void _insertText(String text) {
    final selection = _textController.selection;
    final currentText = _textController.text;

    if (widget.hasLinksFile && text.contains('\n')) {
      // Prevent line breaks in books with links
      UiSnack.show('בספר זה אסור לשנות מבנה שורות כדי לשמור על קישורי פרשנות');
      return;
    }

    // Save undo snapshot before making changes
    if (!_isUndoRedoOperation) {
      _saveToUndoStack(currentText, selection);
    }

    final newText = currentText.replaceRange(
      selection.start,
      selection.end,
      text,
    );

    _isApplyingProgrammaticChange = true;
    _textController.text = newText;
    _textController.selection = TextSelection.collapsed(
      offset: selection.start + text.length,
    );
    _isApplyingProgrammaticChange = false;

    // Mark as changed and sync preview (like _wrapSelection does)
    setState(() {
      _hasUnsavedChanges = true;
      _previewContent = newText;
    });
  }

  void _wrapSelection(String prefix, String suffix) {
    final selection = _textController.selection;
    final currentText = _textController.text;
    final selectedText = selection.textInside(currentText);

    // Don't allow formatting empty selection
    if (selectedText.isEmpty) {
      UiSnack.show('בחר טקסט כדי להחיל עיצוב');
      return;
    }

    // Save current state to undo stack before making programmatic changes
    if (!_isUndoRedoOperation) {
      _saveToUndoStack(currentText, selection);
    }

    // Check if immediately wrapped with tags (tags right before and after selection)
    final hasImmediatePrefix = selection.start >= prefix.length &&
        currentText.substring(
                selection.start - prefix.length, selection.start) ==
            prefix;
    final hasImmediateSuffix = selection.end + suffix.length <=
            currentText.length &&
        currentText.substring(selection.end, selection.end + suffix.length) ==
            suffix;

    String newText;
    TextSelection newSelection;

    if (hasImmediatePrefix && hasImmediateSuffix) {
      // Case 1: Remove formatting - tags are immediately adjacent to selection
      final start = selection.start - prefix.length;
      final end = selection.end + suffix.length;
      newText = currentText.replaceRange(start, end, selectedText);

      newSelection = TextSelection(
        baseOffset: start,
        extentOffset: start + selectedText.length,
      );
    } else if (hasImmediatePrefix || hasImmediateSuffix) {
      // Case 2: Only one side has tags - this is likely an incomplete wrapping, just apply formatting
      // Don't try to unwrap, just add the formatting
      newText = currentText.replaceRange(
        selection.start,
        selection.end,
        '$prefix$selectedText$suffix',
      );

      newSelection = TextSelection(
        baseOffset: selection.start + prefix.length,
        extentOffset: selection.start + prefix.length + selectedText.length,
      );
    } else {
      // Case 3: Check if selection is inside a wrapped block - improved logic
      bool isInsideWrappedBlock = false;
      int blockStartIndex = -1;

      // Look backwards for the CLOSEST opening tag (limit search to reasonable distance)
      final maxSearchDistance = 1000; // מגביל את החיפוש ל-1000 תווים לאחור
      final searchStartPos =
          (selection.start - maxSearchDistance).clamp(0, selection.start);

      for (int i = selection.start - prefix.length; i >= searchStartPos; i--) {
        if (currentText.substring(i, i + prefix.length) == prefix) {
          // בדוק שזה באמת התג הקרוב ביותר - אין תג סגירה ביניהם
          String textBetween =
              currentText.substring(i + prefix.length, selection.start);

          // אם אין תג סגירה ביניהם, זה התג הרלוונטי
          if (!textBetween.contains(suffix)) {
            blockStartIndex = i;
            break;
          }
        }
      }

      // Look forwards for the CLOSEST closing tag if we found an opening tag
      if (blockStartIndex != -1) {
        final searchEndPos = (selection.end + maxSearchDistance)
            .clamp(selection.end, currentText.length);

        for (int i = selection.end; i + suffix.length <= searchEndPos; i++) {
          if (currentText.substring(i, i + suffix.length) == suffix) {
            // בדוק שזה באמת התג הקרוב ביותר - אין תג פתיחה ביניהם
            String textBetween = currentText.substring(selection.end, i);

            // אם אין תג פתיחה ביניהם, זה התג הרלוונטי
            if (!textBetween.contains(prefix)) {
              isInsideWrappedBlock = true;
              break;
            }
          }
        }
      }

      if (isInsideWrappedBlock) {
        // Case 4: Add closing tag at start and opening tag at end to "cut out" the selection from formatting
        newText = currentText;

        // Insert closing tag at start of selection
        newText =
            newText.replaceRange(selection.start, selection.start, suffix);

        // Insert opening tag at end of selection (accounting for inserted suffix)
        newText = newText.replaceRange(selection.end + suffix.length,
            selection.end + suffix.length, prefix);

        // Check if empty tags were created at the insertion point
        final emptyTag = suffix + prefix;
        final emptyTagIndex = newText.indexOf(emptyTag, selection.start);

        if (emptyTagIndex != -1 && emptyTagIndex == selection.start) {
          // The empty tag is right where we inserted it, remove it
          newText = newText.replaceRange(
              emptyTagIndex, emptyTagIndex + emptyTag.length, '');
          newSelection = TextSelection(
            baseOffset: selection.start,
            extentOffset: selection.end,
          );
        } else {
          // Empty tags weren't created, keep adjusted selection
          newSelection = TextSelection(
            baseOffset: selection.start + suffix.length,
            extentOffset: selection.end + suffix.length,
          );
        }
      } else {
        // Case 5: Apply new formatting
        newText = currentText.replaceRange(
          selection.start,
          selection.end,
          '$prefix$selectedText$suffix',
        );

        newSelection = TextSelection(
          baseOffset: selection.start + prefix.length,
          extentOffset: selection.start + prefix.length + selectedText.length,
        );
      }
    }

    _isApplyingProgrammaticChange = true;
    _textController.text = newText;
    _textController.selection = newSelection;
    _isApplyingProgrammaticChange = false;

    // mark as changed and update preview
    setState(() {
      _hasUnsavedChanges = true;
      _previewContent = newText;
    });
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      final isCtrlPressed = HardwareKeyboard.instance.isControlPressed;

      if (isCtrlPressed) {
        switch (event.logicalKey) {
          case LogicalKeyboardKey.keyS:
            _save();
            return true;
          case LogicalKeyboardKey.enter:
            _saveAndClose();
            return true;
          case LogicalKeyboardKey.keyB:
            _wrapSelection('<b>', '</b>');
            return true;
          case LogicalKeyboardKey.keyI:
            _wrapSelection('<i>', '</i>');
            return true;
          case LogicalKeyboardKey.keyK:
            _showLinkDialog();
            return true;
          case LogicalKeyboardKey.keyA:
            // Select all text
            _textController.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _textController.text.length,
            );
            return true;
          case LogicalKeyboardKey.keyF:
            // Open search dialog
            _showSearchDialog();
            return true;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        _discardChanges();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.enter &&
          widget.hasLinksFile) {
        // Prevent Enter in books with links
        UiSnack.show(
            'בספר זה אסור לשנות מבנה שורות כדי לשמור על קישורי פרשנות');
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.f3) {
        // F3 - Find next
        if (_lastSearchText != null && _lastSearchText!.isNotEmpty) {
          _performSearch(_lastSearchText!);
        }
        return true;
      }
    }

    return false;
  }

  // Undo functionality methods
  void _saveToUndoStack(String text, TextSelection selection) {
    if (_isUndoRedoOperation) return;

    // Don't save duplicate consecutive snapshots (skip if text hasn't changed)
    if (_undoStack.isNotEmpty && _undoStack.last == text) {
      return;
    }

    // Remove any redo states if we're adding a new change
    if (_undoIndex < _undoStack.length - 1) {
      _undoStack.removeRange(_undoIndex + 1, _undoStack.length);
      _undoSelectionStack.removeRange(
          _undoIndex + 1, _undoSelectionStack.length);
    }

    _undoStack.add(text);
    _undoSelectionStack.add(selection);
    _undoIndex = _undoStack.length - 1;

    // Limit undo stack to prevent memory issues
    if (_undoStack.length > 50) {
      _undoStack.removeAt(0);
      _undoSelectionStack.removeAt(0);
      _undoIndex--;
    }
  }

  void _undo() {
    if (_undoIndex > 0) {
      _undoIndex--;
      _isUndoRedoOperation = true;
      _textController.text = _undoStack[_undoIndex];
      _textController.selection = _undoSelectionStack[_undoIndex];

      // Cancel any pending debounced preview update to avoid stale content
      _debounceTimer?.cancel();

      // Update UI state to reflect undo
      setState(() {
        _previewContent = _undoStack[_undoIndex];
        _buildPlainTextMap(_undoStack[_undoIndex]); // בנה מפה חדשה אחרי undo
        _lastRenderedContent = _undoStack[_undoIndex];
        _hasUnsavedChanges = _undoStack[_undoIndex] != widget.initialContent;
      });

      _isUndoRedoOperation = false;
    }
  }

  void _onTextChanged() {
    // Skip undo snapshot if this change came from _wrapSelection or _insertText (they already saved snapshot)
    if (!_isUndoRedoOperation && !_isApplyingProgrammaticChange) {
      _saveToUndoStack(_textController.text, _textController.selection);
    }

    setState(() {
      _hasUnsavedChanges = _textController.text != widget.initialContent;
      // עדכן את התצוגה המקדימה מיד כשמקלידים
      _previewContent = _textController.text;
      _buildPlainTextMap(_textController.text);
    });

    // Debounce בנייה של המפה - לא בונים אותה בכל keystroke
    _mapDebounceTimer?.cancel();
    _mapDebounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted) {
        _buildPlainTextMap(_textController.text);
      }
    });

    // Debounce preview updates and render in background
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.settings.previewDebounce, () {
      if (mounted) {
        _renderPreviewInBackground(_textController.text);
      }
    });
  }

  void _onSelectionChanged() {
    // עדכן את הסמן במצב תצוגה מעוצבת כשהמיקום משתנה
    if (_currentViewMode == ViewMode.formatted && mounted) {
      // התחל הבהוב סמן כשהמיקום משתנה
      _startCursorBlinking();
      setState(() {
        // עדכן את ה-UI כדי שהסמן יעבור למיקום החדש
      });
    }
  }

  void _showLinkDialog() {
    showDialog(
      context: context,
      builder: (context) => _LinkInsertDialog(
        onInsert: (text, url) {
          _insertText('[$text]($url)');
        },
      ),
    );
  }

  void _showSearchDialog() {
    showDialog(
      context: context,
      builder: (context) => _SearchDialog(
        onSearch: (searchText) => _performSearch(searchText),
      ),
    );
  }

  void _performSearch(String searchText) {
    if (searchText.isEmpty) return;

    // שמירת טקסט החיפוש עבור F3
    _lastSearchText = searchText;

    final currentText = _textController.text;
    final currentSelection = _textController.selection;

    // Find the search text after current cursor position
    int searchStart = currentSelection.end;
    int foundIndex = currentText.indexOf(searchText, searchStart);

    // If not found from cursor, search from beginning
    if (foundIndex == -1) {
      foundIndex = currentText.indexOf(searchText, 0);
    }

    // If still not found, search case-insensitive
    if (foundIndex == -1) {
      final searchLower = searchText.toLowerCase();
      final textLower = currentText.toLowerCase();
      searchStart = currentSelection.end;
      var tempIndex = textLower.indexOf(searchLower, searchStart);

      // If not found from cursor, search from beginning
      if (tempIndex == -1) {
        tempIndex = textLower.indexOf(searchLower, 0);
      }

      if (tempIndex != -1) {
        foundIndex = tempIndex;
        searchText =
            currentText.substring(tempIndex, tempIndex + searchText.length);
      }
    }

    if (foundIndex != -1) {
      // בדוק שה-ScrollController מוכן לפני השימוש
      if (!_editorScrollController.hasClients) {
        // אם אין clients, פשוט בחר את הטקסט בלי גלילה
        _textController.selection = TextSelection(
          baseOffset: foundIndex,
          extentOffset: foundIndex + searchText.length,
        );
        _editorFocusNode.requestFocus();
        return;
      }

      // הערכה של מיקום הגלילה
      final linesUpToFound =
          '\n'.allMatches(currentText.substring(0, foundIndex)).length;

      const averageLineHeight = 20.0;
      final estimatedScrollOffset = linesUpToFound * averageLineHeight;

      // ודא שהגלילה לא חורגת מהגבולות
      final maxScroll = _editorScrollController.position.maxScrollExtent;
      final targetOffset = estimatedScrollOffset.clamp(0.0, maxScroll);

      // גלול למיקום המוערך
      _editorScrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );

      // Select the found text
      _textController.selection = TextSelection(
        baseOffset: foundIndex,
        extentOffset: foundIndex + searchText.length,
      );

      // Focus the editor
      _editorFocusNode.requestFocus();
    } else {
      // Show not found message
      UiSnack.show('הטקסט לא נמצא');
    }
  }

  /// הסר את כל HTML tags מטקסט
  String _stripHtmlTags(String text) {
    return text.replaceAll(RegExp(r'<[^>]*>'), '');
  }

  /// בנה מפה של plaintext index → original index לביצועים O(n)
  void _buildPlainTextMap(String originalText) {
    _plainToOriginalMap.clear();
    int originalIndex = 0;
    final textLength = originalText.length;

    while (originalIndex < textLength) {
      // דלג על tags - חפש < ואז >
      if (originalText[originalIndex] == '<') {
        // חיפוש אופטימלי של > בלבד - O(1) בממוצע
        int tagEnd = originalIndex + 1;
        while (tagEnd < textLength && originalText[tagEnd] != '>') {
          tagEnd++;
        }

        if (tagEnd < textLength) {
          // מצאנו את סוף ה-tag
          originalIndex = tagEnd + 1;
        } else {
          // אם אין > - זה tag לא תקני, דלג רק על <
          originalIndex++;
        }
      } else {
        // זה טקסט רגיל - הוסף את המיפוי הזה
        _plainToOriginalMap.add(originalIndex);
        originalIndex++;
      }
    }

    // הוסף עמדה סופית לסוף הטקסט
    _plainToOriginalMap.add(originalIndex);
  }

  /// המר עמדות selection מ-plaintext ל-original text בעזרת המפה - O(1)
  int _convertPlainTextIndexToOriginalIndex(int plainIndex) {
    // בדוק אם המפה יצאה מעדכן - אם כן, בנה אותה מיד
    if (_plainToOriginalMap.isEmpty ||
        _lastRenderedContent != _textController.text) {
      _buildPlainTextMap(_textController.text);
    }

    // בדוק גבולות
    if (plainIndex < 0) return 0;
    if (plainIndex >= _plainToOriginalMap.length) {
      return _plainToOriginalMap.isNotEmpty
          ? _plainToOriginalMap.last
          : _previewContent.length;
    }

    return _plainToOriginalMap[plainIndex];
  }

  /// החלף מצב תצוגה
  void _switchViewMode() {
    setState(() {
      switch (_currentViewMode) {
        case ViewMode.formatted:
          _currentViewMode = ViewMode.raw;
          break;
        case ViewMode.raw:
          _currentViewMode = ViewMode.split;
          break;
        case ViewMode.split:
          _currentViewMode = ViewMode.formatted;
          break;
      }
    });

    // התחל הבהוב סמן במצב תצוגה מעוצבת
    if (_currentViewMode == ViewMode.formatted) {
      _startCursorBlinking();
      // בקש פוקוס על העורך כדי שהמקלדת תעבוד
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _editorFocusNode.requestFocus();
        }
      });
    } else {
      _stopCursorBlinking();
    }
  }

  /// התחל הבהוב סמן
  void _startCursorBlinking() {
    _stopCursorBlinking(); // עצור הבהוב קיים
    _showCursor = true;
    _cursorTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (mounted) {
        setState(() {
          _showCursor = !_showCursor;
        });
      }
    });
  }

  /// עצור הבהוב סמן
  void _stopCursorBlinking() {
    _cursorTimer?.cancel();
    _cursorTimer = null;
    if (mounted) {
      setState(() {
        _showCursor = false;
      });
    }
  }

  /// ניווט לכותרת לפי מיקום בטקסט
  void _navigateToHeader(int position) {
    if (!_editorScrollController.hasClients) return;

    // הערכה של מיקום הגלילה
    final textUpToPosition = _textController.text.substring(0, position);
    final linesUpToPosition = '\n'.allMatches(textUpToPosition).length;

    const averageLineHeight = 20.0;
    final estimatedScrollOffset = linesUpToPosition * averageLineHeight;

    // ודא שהגלילה לא חורגת מהגבולות
    final maxScroll = _editorScrollController.position.maxScrollExtent;
    final targetOffset = estimatedScrollOffset.clamp(0.0, maxScroll);

    // גלול למיקום המוערך
    _editorScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );

    // הצב את הסמן במיקום הכותרת
    _textController.selection = TextSelection.collapsed(offset: position);

    // בקש פוקוס על העורך
    _editorFocusNode.requestFocus();
  }

  /// קבל את הטקסט לתצוגה לפי המצב הנוכחי
  String _getViewModeTitle() {
    switch (_currentViewMode) {
      case ViewMode.formatted:
        return 'תצוגה מעוצבת';
      case ViewMode.raw:
        return 'טקסט גולמי';
      case ViewMode.split:
        return 'מצב משולב';
    }
  }

  /// קבל את האייקון לתצוגה לפי המצב הנוכחי
  IconData _getViewModeIcon() {
    switch (_currentViewMode) {
      case ViewMode.formatted:
        return FluentIcons.document_text_24_regular;
      case ViewMode.raw:
        return FluentIcons.code_24_regular;
      case ViewMode.split:
        return FluentIcons.split_horizontal_24_regular;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '${_hasUnsavedChanges ? 'שינויים שלא נשמרו • ' : ''}עריכת טקסט - ${widget.bookId}',
            style: const TextStyle(fontSize: 16),
          ),
          leading: IconButton(
            icon: const Icon(FluentIcons.dismiss_24_regular),
            onPressed: _discardChanges,
          ),
          actions: [
            TextButton.icon(
              onPressed: _hasUnsavedChanges ? _save : null,
              icon: const Icon(FluentIcons.save_24_regular),
              label: const Text('שמור'),
            ),
            TextButton.icon(
              onPressed: _saveAndClose,
              icon: const Icon(FluentIcons.save_arrow_right_24_regular),
              label: const Text('שמור וצא'),
            ),
          ],
        ),
        body: Row(
          children: [
            // סרגל הכותרות - צד שמאל של כל המסך
            Container(
              width: 200,
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: theme.dividerColor)),
              ),
              child: Column(
                children: [
                  // רשימת הכותרות
                  Expanded(
                    child: EditorHeadersBar(
                      content: _textController.text,
                      editorScrollController: _editorScrollController,
                      textController: _textController,
                      onHeaderTap: _navigateToHeader,
                    ),
                  ),
                ],
              ),
            ),
            // שאר התוכן - עריכה ותצוגה
            Expanded(
              child: Column(
                children: [
                  // סרגל הכלים - משותף לכל הרוחב
                  MarkdownToolbar(
                    onBold: () => _wrapSelection('<b>', '</b>'),
                    onItalic: () => _wrapSelection('<i>', '</i>'),
                    onHeader1: () => _wrapSelection('<h1>', '</h1>'),
                    onHeader2: () => _wrapSelection('<h2>', '</h2>'),
                    onHeader3: () => _wrapSelection('<h3>', '</h3>'),
                    onUnorderedList: () =>
                        _wrapSelection('<ul>\n<li>', '</li>\n</ul>'),
                    onOrderedList: () =>
                        _wrapSelection('<ol>\n<li>', '</li>\n</ol>'),
                    onLink: _showLinkDialog,
                    onCode: () => _wrapSelection('<code>', '</code>'),
                    onQuote: () =>
                        _wrapSelection('<blockquote>', '</blockquote>'),
                    onUndo: _undo,
                    onRedo: () {/* TODO: Implement redo */},
                    onSearch: _showSearchDialog,
                    onViewModeSwitch: _switchViewMode,
                    viewModeIcon: _getViewModeIcon(),
                    viewModeTooltip: _getViewModeTitle(),
                    hasLinksFile: widget.hasLinksFile,
                  ),
                  // התוכן עצמו (בלי סרגל הכותרות)
                  Expanded(
                    child: _buildViewContent(theme),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// בנה את התוכן לפי מצב התצוגה הנוכחי
  Widget _buildViewContent(ThemeData theme) {
    switch (_currentViewMode) {
      case ViewMode.formatted:
        return _buildFormattedView(theme);
      case ViewMode.raw:
        return _buildRawView(theme);
      case ViewMode.split:
        return _buildSplitView(theme);
    }
  }

  /// מצב תצוגה מעוצבת - תצוגה מקדימה עם סמן המראה את המיקום בעורך
  Widget _buildFormattedView(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: TextField(
        scrollController: _editorScrollController,
        controller: _textController,
        focusNode: _editorFocusNode,
        maxLines: null,
        expands: true,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(
          fontSize: 16,
          fontFamily: 'TaameyAshkenaz',
          height: 1.5,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: 'התחל לכתוב כאן...',
          hintTextDirection: TextDirection.rtl,
        ),
        onChanged: (text) {
          // הפונקציה _onTextChanged תטפל בעדכון
        },
      ),
    );
  }

  /// מצב טקסט גולמי - רק עורך
  Widget _buildRawView(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: TextField(
        scrollController: _editorScrollController,
        controller: _textController,
        focusNode: _editorFocusNode,
        maxLines: null,
        expands: true,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(
          fontSize: 16,
          fontFamily: 'TaameyAshkenaz',
          height: 1.5,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: 'התחל לכתוב כאן...',
          hintTextDirection: TextDirection.rtl,
        ),
        onChanged: (text) {
          // הפונקציה _onTextChanged תטפל בעדכון
        },
      ),
    );
  }

  /// מצב משולב - עורך + תצוגה מקדימה
  Widget _buildSplitView(ThemeData theme) {
    return Row(
      children: [
        // חלונית העריכה (ימין)
        Expanded(
          flex: 1,
          child: Container(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: theme.dividerColor)),
            ),
            padding: const EdgeInsets.all(16),
            child: TextField(
              scrollController: _editorScrollController,
              controller: _textController,
              focusNode: _editorFocusNode,
              maxLines: null,
              expands: true,
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.right,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                fontSize: 16,
                fontFamily: 'TaameyAshkenaz',
                height: 1.5,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'התחל לכתוב כאן...',
                hintTextDirection: TextDirection.rtl,
              ),
              onChanged: (text) {
                // הפונקציה _onTextChanged תטפל בעדכון
              },
            ),
          ),
        ),
        // חלונית התצוגה המקדימה (שמאל)
        Expanded(
          flex: 1,
          child: SingleChildScrollView(
            controller: _previewScrollController,
            padding: const EdgeInsets.all(16),
            child: SelectionArea(
              onSelectionChanged: (SelectedContent? selectedContent) {
                if (selectedContent != null &&
                    selectedContent.plainText.isNotEmpty) {
                  final selectedText = selectedContent.plainText;
                  final originalText = _textController.text;
                  final plainText = _stripHtmlTags(originalText);
                  final selectedIndex = plainText.indexOf(selectedText);

                  if (selectedIndex != -1) {
                    final originalStart =
                        _convertPlainTextIndexToOriginalIndex(selectedIndex);
                    final originalEnd = _convertPlainTextIndexToOriginalIndex(
                        selectedIndex + selectedText.length);

                    if (originalStart >= 0 &&
                        originalEnd <= originalText.length &&
                        originalStart <= originalEnd) {
                      _textController.selection = TextSelection(
                        baseOffset: originalStart,
                        extentOffset: originalEnd,
                      );

                      Future.delayed(const Duration(milliseconds: 50), () {
                        _editorFocusNode.requestFocus();
                      });
                    }
                  }
                }
              },
              child: _previewRenderer.renderPreview(
                markdown: _previewContent,
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontFamily: 'TaameyAshkenaz',
                ),
                fontFamily: 'TaameyAshkenaz',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dialog for search functionality
class _SearchDialog extends StatefulWidget {
  final Function(String) onSearch;

  const _SearchDialog({required this.onSearch});

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('חיפוש בטקסט'),
      content: TextField(
        controller: _searchController,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'הכנס טקסט לחיפוש...',
          border: OutlineInputBorder(),
        ),
        textDirection: TextDirection.rtl,
        onSubmitted: (value) {
          if (value.isNotEmpty) {
            widget.onSearch(value);
            Navigator.of(context).pop();
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('ביטול'),
        ),
        TextButton(
          onPressed: () {
            if (_searchController.text.isNotEmpty) {
              widget.onSearch(_searchController.text);
              Navigator.of(context).pop();
            }
          },
          child: const Text('חפש'),
        ),
      ],
    );
  }
}

/// Dialog for inserting links
class _LinkInsertDialog extends StatefulWidget {
  final Function(String text, String url) onInsert;

  const _LinkInsertDialog({required this.onInsert});

  @override
  State<_LinkInsertDialog> createState() => _LinkInsertDialogState();
}

class _LinkInsertDialogState extends State<_LinkInsertDialog> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (DismissIntent intent) {
            Navigator.of(context).pop();
            return null;
          },
        ),
      },
      child: AlertDialog(
        title: const Text('הוסף קישור'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _textController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'טקסט הקישור',
                hintText: 'לחץ כאן',
              ),
              textDirection: TextDirection.rtl,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'כתובת URL',
                hintText: 'https://example.com',
              ),
              textDirection: TextDirection.ltr,
              onSubmitted: (_) {
                widget.onInsert(_textController.text, _urlController.text);
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('ביטול'),
          ),
          TextButton(
            onPressed: () {
              widget.onInsert(_textController.text, _urlController.text);
              Navigator.of(context).pop();
            },
            child: const Text('הוסף'),
          ),
        ],
      ),
    );
  }
}
