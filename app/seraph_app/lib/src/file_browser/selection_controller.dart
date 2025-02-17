
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class SelectionController with ChangeNotifier {
  
  SelectionController({this.scrollController});

  ScrollController? scrollController;
  double _storedOffset = 0.0;


  Set<String> _selectedItems = {};

  get isSelecting => _selectedItems.isNotEmpty;
  get numSelected => _selectedItems.length;

  clearSelection() {
    if (_selectedItems.isNotEmpty) {
      _restoreScrollPosition();
    }
    _selectedItems = {};
    notifyListeners();
  }

  add(String s) {
    if (_selectedItems.isEmpty) {
      _restoreScrollPosition();
    }
    _selectedItems.add(s);
    notifyListeners();
  }

  remove(String s) {
    if (_selectedItems.length == 1) {
      _restoreScrollPosition();
    }
    _selectedItems.remove(s);
    notifyListeners();
  }

  isSelected(String? s) {
    if (s == null) {
      return false;
    }
    return _selectedItems.contains(s);
  }

  _restoreScrollPosition() {
    if (scrollController != null) {
      _storedOffset = scrollController!.offset;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        scrollController!.jumpTo(_storedOffset);
      });
    }
  }
}