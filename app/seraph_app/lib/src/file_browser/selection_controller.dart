
import 'package:flutter/material.dart';

class SelectionController with ChangeNotifier {
  
  Set<String> _selectedItems = {};

  get isSelecting => _selectedItems.isNotEmpty;
  get numSelected => _selectedItems.length;

  clearSelection() {
    _selectedItems = {};
    notifyListeners();
  }

  add(String s) {
    _selectedItems.add(s);
    notifyListeners();
  }

  remove(String s) {
    _selectedItems.remove(s);
    notifyListeners();
  }

  isSelected(String? s) {
    if (s == null) {
      return false;
    }
    return _selectedItems.contains(s);
  }
}