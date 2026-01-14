import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

/// Represents a header entry in the document
class HeaderEntry {
  final String text;
  final int level; // 1-6 for h1-h6
  final int position; // Character position in the document
  final List<HeaderEntry> children;
  HeaderEntry? parent;

  HeaderEntry({
    required this.text,
    required this.level,
    required this.position,
    List<HeaderEntry>? children,
    this.parent,
  }) : children = children ?? <HeaderEntry>[];
}

/// A widget that displays document headers in a hierarchical navigation bar
class EditorHeadersBar extends StatefulWidget {
  final String content;
  final ScrollController editorScrollController;
  final TextEditingController textController;
  final Function(int position) onHeaderTap;

  const EditorHeadersBar({
    super.key,
    required this.content,
    required this.editorScrollController,
    required this.textController,
    required this.onHeaderTap,
  });

  @override
  State<EditorHeadersBar> createState() => _EditorHeadersBarState();
}

class _EditorHeadersBarState extends State<EditorHeadersBar> {
  List<HeaderEntry> _headers = [];
  final Map<int, bool> _expanded = {};
  int? _activeHeaderIndex;
  Timer? _scrollDebounceTimer;

  @override
  void initState() {
    super.initState();
    _parseHeaders();
    widget.editorScrollController.addListener(_onEditorScroll);
  }

  @override
  void dispose() {
    _scrollDebounceTimer?.cancel();
    widget.editorScrollController.removeListener(_onEditorScroll);
    super.dispose();
  }

  @override
  void didUpdateWidget(EditorHeadersBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _parseHeaders();
    }
  }

  void _onEditorScroll() {
    _scrollDebounceTimer?.cancel();
    _scrollDebounceTimer = Timer(const Duration(milliseconds: 100), () {
      _updateActiveHeader();
    });
  }

  void _updateActiveHeader() {
    if (!mounted || _headers.isEmpty) return;

    final scrollOffset = widget.editorScrollController.offset;
    final textLength = widget.textController.text.length;
    
    if (textLength == 0) return;

    // Estimate current cursor position based on scroll
    final scrollFraction = widget.editorScrollController.hasClients
        ? scrollOffset / (widget.editorScrollController.position.maxScrollExtent + 1)
        : 0.0;
    final estimatedPosition = (scrollFraction * textLength).round();

    // Get all headers (including children) in a flat list
    final allHeaders = <HeaderEntry>[];
    void collectHeaders(List<HeaderEntry> headers) {
      for (final header in headers) {
        allHeaders.add(header);
        collectHeaders(header.children);
      }
    }
    collectHeaders(_headers);

    // Find the closest header
    int? closestHeaderIndex;
    int minDistance = textLength;

    for (int i = 0; i < allHeaders.length; i++) {
      final distance = (estimatedPosition - allHeaders[i].position).abs();
      if (distance < minDistance) {
        minDistance = distance;
        closestHeaderIndex = i;
      }
    }

    if (closestHeaderIndex != _activeHeaderIndex) {
      setState(() {
        _activeHeaderIndex = closestHeaderIndex;
      });
    }
  }

  void _parseHeaders() {
    final headers = <HeaderEntry>[];
    final content = widget.content;
    
    // Regex to match HTML headers h1-h6
    final headerRegex = RegExp(r'<h([1-6])[^>]*>(.*?)</h[1-6]>', 
        caseSensitive: false, multiLine: true, dotAll: true);
    
    final matches = headerRegex.allMatches(content);
    final List<HeaderEntry> flatHeaders = [];
    
    for (final match in matches) {
      final level = int.parse(match.group(1)!);
      final text = match.group(2)!
          .replaceAll(RegExp(r'<[^>]*>'), '') // Remove HTML tags
          .trim();
      
      if (text.isNotEmpty) {
        flatHeaders.add(HeaderEntry(
          text: text,
          level: level,
          position: match.start,
        ));
      }
    }

    // Build hierarchy
    _headers = _buildHierarchy(flatHeaders);
    
    // Initialize expanded state for level 1 headers
    _expanded.clear();
    for (int i = 0; i < _headers.length; i++) {
      if (_headers[i].level == 1) {
        _expanded[i] = true;
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  List<HeaderEntry> _buildHierarchy(List<HeaderEntry> flatHeaders) {
    if (flatHeaders.isEmpty) return [];

    final List<HeaderEntry> result = [];
    final List<HeaderEntry> stack = [];

    for (final header in flatHeaders) {
      // Remove headers from stack that are at same or deeper level
      while (stack.isNotEmpty && stack.last.level >= header.level) {
        stack.removeLast();
      }

      // Create a new header entry with mutable children list
      final newHeader = HeaderEntry(
        text: header.text,
        level: header.level,
        position: header.position,
        children: <HeaderEntry>[],
      );

      // Set parent if there's a header in the stack
      if (stack.isNotEmpty) {
        newHeader.parent = stack.last;
        stack.last.children.add(newHeader);
      } else {
        result.add(newHeader);
      }

      stack.add(newHeader);
    }

    return result;
  }

  Widget _buildHeaderItem(HeaderEntry header, int index) {
    final isActive = _activeHeaderIndex == index;
    final hasChildren = header.children.isNotEmpty;
    final isExpanded = _expanded[index] ?? false;

    return Column(
      children: [
        InkWell(
          onTap: () {
            if (hasChildren) {
              setState(() {
                _expanded[index] = !isExpanded;
              });
            } else {
              widget.onHeaderTap(header.position);
            }
          },
          child: Container(
            padding: EdgeInsets.only(
              right: 16.0 + (header.level - 1) * 20.0,
              left: 16.0,
              top: 8.0,
              bottom: 8.0,
            ),
            decoration: BoxDecoration(
              color: isActive
                  ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : null,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  hasChildren
                      ? FluentIcons.book_24_regular
                      : FluentIcons.text_bullet_list_24_regular,
                  color: hasChildren
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.secondary,
                  size: hasChildren ? 18 : 16,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    header.text,
                    style: TextStyle(
                      fontSize: hasChildren ? 14 : 13,
                      fontWeight: hasChildren ? FontWeight.w600 : FontWeight.normal,
                      color: hasChildren
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasChildren)
                  Icon(
                    isExpanded
                        ? FluentIcons.chevron_up_24_regular
                        : FluentIcons.chevron_down_24_regular,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 16,
                  ),
              ],
            ),
          ),
        ),
        if (hasChildren && isExpanded)
          ...header.children.asMap().entries.map((entry) {
            final childIndex = _headers.length + entry.key; // Unique index for child
            return _buildHeaderItem(entry.value, childIndex);
          }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_headers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              FluentIcons.document_header_24_regular,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              'אין כותרות במסמך',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Icon(
                FluentIcons.document_header_24_regular,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              const Text(
                'כותרות',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _headers.length,
            itemBuilder: (context, index) => _buildHeaderItem(_headers[index], index),
          ),
        ),
      ],
    );
  }
}