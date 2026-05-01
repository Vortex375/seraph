import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';

class ProviderPickerDialog extends StatefulWidget {
  const ProviderPickerDialog({super.key});

  @override
  State<ProviderPickerDialog> createState() => _ProviderPickerDialogState();
}

class _ProviderPickerDialogState extends State<ProviderPickerDialog> {
  final SpacesService spacesService = Get.find();
  List<ServiceAnnouncement>? _services;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadServices();
  }

  Future<void> _loadServices() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      _services = await spacesService.listServices();
    } catch (e) {
      _error = 'Failed to load services: $e';
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select File Provider'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _buildContent(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadServices,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final services = _services?.where((s) => s.serviceType == 'file-provider').toList();
    if (services == null || services.isEmpty) {
      return const Center(child: Text('No file providers available'));
    }

    return ListView.builder(
      itemCount: services.length,
      itemBuilder: (context, index) {
        final service = services[index];
        final providerId = service.properties['id'] ?? service.instanceId;
        final kind = service.properties['kind'] ?? '';
        return ListTile(
          title: Text(providerId),
          subtitle: kind.isNotEmpty ? Text('Kind: $kind') : null,
          onTap: () {
            Navigator.of(context).pop(
              SpaceFileProvider(
                spaceProviderId: providerId,
                providerId: providerId,
                path: '/',
                readOnly: false,
              ),
            );
          },
        );
      },
    );
  }
}
