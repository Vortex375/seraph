
import 'package:get/get.dart';

class SelectionController extends GetxController {

  final RxSet<String> _selectedItems = <String>{}.obs;
  final RxBool _isSelecting = false.obs;
  final RxInt _numSelected = 0.obs;

   RxBool get isSelecting => _isSelecting;
   RxInt get numSelected => _numSelected;

  late List<Worker> _workers;

  @override
  void onInit() {
    super.onInit();
    _workers = [
      ever(_selectedItems, (v) => _isSelecting(v.isNotEmpty)),
      ever(_selectedItems, (v) => _numSelected(v.length)),
    ];
  }

  @override
  void onClose() {
    super.onClose();
    for (var w in _workers) {
      w.dispose();
    }
  }

  clearSelection() {
    _selectedItems.clear();
  }

  add(String s) {
    _selectedItems.add(s);
  }

  remove(String s) {
    _selectedItems.remove(s);
  }

  isSelected(String? s) {
    if (s == null) {
      return false;
    }
    return _selectedItems.contains(s);
  }
}