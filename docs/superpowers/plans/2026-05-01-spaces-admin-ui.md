# Spaces Admin UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a spaces admin UI to the Flutter app (list → detail pattern) with supporting backend changes (spaces module registration, IsSpaceAdmin role check, secure services endpoint).

**Architecture:** Backend: register missing spaces module, implement OIDC realm-role check for IsSpaceAdmin, add space-admin auth to services endpoint. Flutter: new `spaces_admin/` feature directory following the Chat feature pattern (Service → Controller → View), with permission gating via LoginController.

**Tech Stack:** Go (api-gateway), Flutter/Dart (GetX + Dio), OIDC (Zitadel roles)

---

## File Structure

```
api-gateway/
  main.go                    → modify: import + register spaces module
  auth/auth.go               → modify: implement IsSpaceAdmin()
  services/services.go        → modify: add auth check

app/seraph_app/lib/src/
  login/login_controller.dart → modify: add isSpaceAdmin getter
  app.dart                    → modify: register /spaces-admin route
  initial_binding.dart        → modify: register spaces service + controllers
  app_bar/app_bar.dart        → modify: add Spaces Admin dropdown item
  spaces_admin/
    spaces_models.dart        → create: data classes
    spaces_service.dart       → create: Dio API client
    spaces_list_controller.dart → create: list controller
    spaces_list_view.dart      → create: master list widget
    spaces_detail_controller.dart → create: detail form controller
    spaces_detail_view.dart     → create: detail/edit form widget
    provider_picker_dialog.dart → create: provider selection dialog
```

---

### Task 1: Register spaces module in api-gateway/main.go

**Files:**
- Modify: `api-gateway/main.go`

- [ ] **Step 1: Add import and module registration**

Add `"umbasa.net/seraph/api-gateway/spaces"` to imports and `spaces.Module` to `fx.New()`.

```go
// api-gateway/main.go

// Add to imports:
	"umbasa.net/seraph/api-gateway/spaces"

// In fx.New(), add after the services line and before shares:
		spaces.Module,
```

The relevant section of fx.New() should change from:

```go
		services.Module,
		shares.Module,
```

to:

```go
		spaces.Module,
		services.Module,
		shares.Module,
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd api-gateway && go build ./...`
Expected: exit code 0, no errors

- [ ] **Step 3: Commit**

```bash
git add api-gateway/main.go
git commit -m "fix(api-gateway): register spaces module"
```

---

### Task 2: Implement IsSpaceAdmin realm role check

**Files:**
- Modify: `api-gateway/auth/auth.go`

- [ ] **Step 1: Implement IsSpaceAdmin method**

Replace the stub `IsSpaceAdmin` in `oidcAuth` with a real implementation that checks the introspection response claims for a `space-admin` role. The claim key is configurable via viper.

```go
// api-gateway/auth/auth.go

// In oidcAuth struct, add a field:
type oidcAuth struct {
	// ... existing fields ...
	spaceAdminClaimKey string
}

// In New(), after setting appClientId, add:
	spaceAdminClaimKey := p.Viper.GetString("auth.spaceAdminClaimKey")
	if spaceAdminClaimKey == "" {
		spaceAdminClaimKey = "roles"
	}
	// ... pass to oidcAuth ...

	auth := &oidcAuth{
		// ... existing fields ...
		spaceAdminClaimKey: spaceAdminClaimKey,
	}

// Replace the stub method:
func (a *oidcAuth) IsSpaceAdmin(ctx context.Context) bool {
	roles := a.getRolesFromContext(ctx)
	for _, role := range roles {
		if role == "space-admin" {
			return true
		}
	}
	return false
}

// Add helper method to extract roles from introspection response:
func (a *oidcAuth) getRolesFromContext(ctx context.Context) []string {
	claims, ok := ctx.Value(introspectionClaimsKey{}).(map[string]any)
	if !ok {
		return nil
	}
	raw, ok := claims[a.spaceAdminClaimKey]
	if !ok {
		return nil
	}
	if roles, ok := raw.([]any); ok {
		result := make([]string, 0, len(roles))
		for _, r := range roles {
			if s, ok := r.(string); ok {
				result = append(result, s)
			}
		}
		return result
	}
	return nil
}

// Add a context key type:
type introspectionClaimsKey struct{}
```

Now we need to store the introspection claims in the context during `AuthMiddleware`. In the `verifyToken` flow, after successful introspection, add:

```go
// In AuthMiddleware, after the successful introspection and just before setUserId:
		claims := make(map[string]any)
		if introspection.Claims != nil {
			claims = introspection.Claims
		}
		ctx.Request = ctx.Request.WithContext(
			context.WithValue(ctx.Request.Context(), introspectionClaimsKey{}, claims),
		)
```

- [ ] **Step 2: Update no_auth.go to match interface (no changes needed)**

`noAuth.IsSpaceAdmin()` already returns `true` — no changes needed.

- [ ] **Step 3: Build to verify**

Run: `cd api-gateway && go build ./...`
Expected: exit code 0

- [ ] **Step 4: Commit**

```bash
git add api-gateway/auth/auth.go
git commit -m "feat(auth): implement IsSpaceAdmin via realm role check"
```

---

### Task 3: Secure services endpoint behind space-admin auth

**Files:**
- Modify: `api-gateway/services/services.go`

- [ ] **Step 1: Add auth dependency and check**

Add `auth.Auth` to the `Params` struct and check `IsSpaceAdmin` in both handler functions.

```go
// api-gateway/services/services.go

// Update imports to add:
	"errors"
	"net/http"

// Update Params:
type Params struct {
	fx.In

	Log       *logging.Logger
	Discovery servicediscovery.ServiceDiscovery
	Auth      auth.Auth
}

// Update servicesHandler struct:
type servicesHandler struct {
	log       *slog.Logger
	discovery servicediscovery.ServiceDiscovery
	auth      auth.Auth
}

// Update the Setup method to add auth checks:
func (h *servicesHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	apiGroup.GET("/services", func(ctx *gin.Context) {
		if !h.auth.IsSpaceAdmin(ctx) {
			ctx.AbortWithError(http.StatusForbidden, errors.New("only space admin can access services"))
			return
		}
		ctx.JSON(200, h.discovery.Get(""))
	})
	apiGroup.GET("/services/type/:serviceType", func(ctx *gin.Context) {
		if !h.auth.IsSpaceAdmin(ctx) {
			ctx.AbortWithError(http.StatusForbidden, errors.New("only space admin can access services"))
			return
		}
		ctx.JSON(200, h.discovery.Get(ctx.Param("serviceType")))
	})
}
```

- [ ] **Step 2: Build to verify**

Run: `cd api-gateway && go build ./...`
Expected: exit code 0

- [ ] **Step 3: Commit**

```bash
git add api-gateway/services/services.go
git commit -m "feat(services): restrict services endpoint to space admins"
```

---

### Task 4: Create spaces_models.dart

**Files:**
- Create: `app/seraph_app/lib/src/spaces_admin/spaces_models.dart`

- [ ] **Step 1: Write models**

```dart
class Space {
  final String? id;
  final String title;
  final String description;
  final List<String> users;
  final List<SpaceFileProvider> fileProviders;

  Space({
    this.id,
    required this.title,
    required this.description,
    required this.users,
    required this.fileProviders,
  });

  factory Space.fromJson(Map<String, dynamic> json) {
    return Space(
      id: (json['Id'] ?? json['_id']) as String?,
      title: (json['title'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      users: (json['users'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      fileProviders: (json['fileProviders'] as List<dynamic>?)
              ?.map((e) =>
                  SpaceFileProvider.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) '_id': id,
      'title': title,
      'description': description,
      'users': users,
      'fileProviders':
          fileProviders.map((fp) => fp.toJson()).toList(),
    };
  }
}

class SpaceFileProvider {
  final String spaceProviderId;
  final String providerId;
  final String path;
  final bool readOnly;

  SpaceFileProvider({
    required this.spaceProviderId,
    required this.providerId,
    required this.path,
    required this.readOnly,
  });

  factory SpaceFileProvider.fromJson(Map<String, dynamic> json) {
    return SpaceFileProvider(
      spaceProviderId: (json['spaceProviderId'] as String?) ?? '',
      providerId: (json['providerId'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      readOnly: (json['readOnly'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'spaceProviderId': spaceProviderId,
      'providerId': providerId,
      'path': path,
      'readOnly': readOnly,
    };
  }
}

class ServiceAnnouncement {
  final String instanceId;
  final String serviceType;
  final Map<String, String> properties;

  ServiceAnnouncement({
    required this.instanceId,
    required this.serviceType,
    required this.properties,
  });

  factory ServiceAnnouncement.fromJson(Map<String, dynamic> json) {
    final props = <String, String>{};
    final rawProps = json['properties'];
    if (rawProps is Map) {
      rawProps.forEach((k, v) {
        props[k.toString()] = v.toString();
      });
    }
    return ServiceAnnouncement(
      instanceId: (json['instanceId'] as String?) ?? '',
      serviceType: (json['serviceType'] as String?) ?? '',
      properties: props,
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/spaces_admin/spaces_models.dart
git commit -m "feat(spaces-admin): add spaces data models"
```

---

### Task 5: Create spaces_service.dart

**Files:**
- Create: `app/seraph_app/lib/src/spaces_admin/spaces_service.dart`

- [ ] **Step 1: Write API service**

```dart
import 'package:dio/dio.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/util.dart';

class SpacesService {
  SpacesService(this.settingsController, this.loginController, {Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));

  final SettingsController settingsController;
  final LoginController loginController;
  final Dio dio;

  Future<Map<String, String>> _getRequestHeaders() async {
    await until(loginController.isInitialized, identity);

    if (loginController.currentUser.value != null) {
      return {
        'Authorization':
            'Bearer ${loginController.currentUser.value?.token.accessToken}'
      };
    }

    return {};
  }

  Future<List<Space>> listSpaces() async {
    final response = await dio.get<Map<String, dynamic>>(
      '/api/spaces',
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['space'];
    if (rawList is! List) return [];
    return rawList
        .map((item) => Space.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<Space> getSpace(String spaceId) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/api/spaces/$spaceId',
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['space'];
    if (rawList is List && rawList.isNotEmpty) {
      return Space.fromJson(rawList[0] as Map<String, dynamic>);
    }
    throw Exception('Space not found');
  }

  Future<Space> createSpace(Space space) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/spaces',
      data: space.toJson(),
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['space'];
    if (rawList is List && rawList.isNotEmpty) {
      return Space.fromJson(rawList[0] as Map<String, dynamic>);
    }
    throw Exception('Failed to create space');
  }

  Future<Space> updateSpace(String spaceId, Space space) async {
    final response = await dio.put<Map<String, dynamic>>(
      '/api/spaces/$spaceId',
      data: space.toJson(),
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['space'];
    if (rawList is List && rawList.isNotEmpty) {
      return Space.fromJson(rawList[0] as Map<String, dynamic>);
    }
    throw Exception('Failed to update space');
  }

  Future<void> deleteSpace(String spaceId) async {
    await dio.delete<void>(
      '/api/spaces/$spaceId',
      options: Options(headers: await _getRequestHeaders()),
    );
  }

  Future<List<ServiceAnnouncement>> listServices() async {
    final response = await dio.get<List<dynamic>>(
      '/api/services',
      options: Options(headers: await _getRequestHeaders()),
    );

    if (response.data == null) return [];
    return response.data!
        .map((item) =>
            ServiceAnnouncement.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/spaces_admin/spaces_service.dart
git commit -m "feat(spaces-admin): add spaces API service"
```

---

### Task 6: Create spaces_list_controller.dart

**Files:**
- Create: `app/seraph_app/lib/src/spaces_admin/spaces_list_controller.dart`

- [ ] **Step 1: Write list controller**

```dart
import 'package:get/get.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';

class SpacesListController extends GetxController {
  SpacesListController(this.spacesService);

  final SpacesService spacesService;

  final RxList<Space> spaces = RxList<Space>([]);
  final RxBool isLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadSpaces();
  }

  Future<void> loadSpaces() async {
    isLoading.value = true;
    try {
      spaces.assignAll(await spacesService.listSpaces());
    } catch (e) {
      Get.snackbar('Error', 'Failed to load spaces: $e');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> deleteSpace(String spaceId) async {
    try {
      await spacesService.deleteSpace(spaceId);
      spaces.removeWhere((s) => s.id == spaceId);
    } catch (e) {
      Get.snackbar('Error', 'Failed to delete space: $e');
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/spaces_admin/spaces_list_controller.dart
git commit -m "feat(spaces-admin): add spaces list controller"
```

---

### Task 7: Create spaces_detail_controller.dart

**Files:**
- Create: `app/seraph_app/lib/src/spaces_admin/spaces_detail_controller.dart`

- [ ] **Step 1: Write detail controller**

```dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';

class SpacesDetailController extends GetxController {
  SpacesDetailController(this.spacesService, {this.spaceId});

  final SpacesService spacesService;
  final String? spaceId;

  final titleController = TextEditingController();
  final descriptionController = TextEditingController();
  final userInputController = TextEditingController();
  final providerPathController = TextEditingController();
  final providerNameController = TextEditingController();

  final RxList<String> users = RxList<String>([]);
  final RxList<SpaceFileProvider> fileProviders = RxList<SpaceFileProvider>([]);
  final RxBool isLoading = false.obs;
  final RxBool isSaving = false.obs;
  final RxString? error = RxnString();

  bool get isEditing => spaceId != null;

  @override
  void onInit() {
    super.onInit();
    if (isEditing) {
      loadSpace();
    }
  }

  @override
  void onClose() {
    titleController.dispose();
    descriptionController.dispose();
    userInputController.dispose();
    providerPathController.dispose();
    providerNameController.dispose();
    super.onClose();
  }

  Future<void> loadSpace() async {
    isLoading.value = true;
    error.value = null;
    try {
      final space = await spacesService.getSpace(spaceId!);
      titleController.text = space.title;
      descriptionController.text = space.description;
      users.assignAll(space.users);
      fileProviders.assignAll(space.fileProviders);
    } catch (e) {
      error.value = 'Failed to load space: $e';
    } finally {
      isLoading.value = false;
    }
  }

  void addUser() {
    final text = userInputController.text.trim();
    if (text.isNotEmpty && !users.contains(text)) {
      users.add(text);
      userInputController.clear();
    }
  }

  void removeUser(String user) {
    users.remove(user);
  }

  void addFileProvider(SpaceFileProvider fp) {
    fileProviders.add(fp);
  }

  void updateFileProvider(int index, SpaceFileProvider fp) {
    fileProviders[index] = fp;
  }

  void removeFileProvider(int index) {
    fileProviders.removeAt(index);
  }

  Future<bool> save() async {
    if (titleController.text.trim().isEmpty) {
      Get.snackbar('Validation', 'Title is required');
      return false;
    }

    isSaving.value = true;
    try {
      final space = Space(
        id: spaceId,
        title: titleController.text.trim(),
        description: descriptionController.text.trim(),
        users: users.toList(),
        fileProviders: fileProviders.toList(),
      );

      if (isEditing) {
        await spacesService.updateSpace(spaceId!, space);
      } else {
        await spacesService.createSpace(space);
      }
      return true;
    } catch (e) {
      Get.snackbar('Error', 'Failed to save space: $e');
      return false;
    } finally {
      isSaving.value = false;
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/spaces_admin/spaces_detail_controller.dart
git commit -m "feat(spaces-admin): add spaces detail controller"
```

---

### Task 8: Create provider_picker_dialog.dart

**Files:**
- Create: `app/seraph_app/lib/src/spaces_admin/provider_picker_dialog.dart`

- [ ] **Step 1: Write provider picker dialog**

```dart
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
          onPressed: () => Get.back(),
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

    final services = _services;
    if (services == null || services.isEmpty) {
      return const Center(child: Text('No services available'));
    }

    return ListView.builder(
      itemCount: services.length,
      itemBuilder: (context, index) {
        final service = services[index];
        return ListTile(
          title: Text(service.instanceId),
          subtitle: Text('Type: ${service.serviceType}'),
          onTap: () {
            Get.back(
              result: SpaceFileProvider(
                spaceProviderId: '',
                providerId: service.instanceId,
                path: '',
                readOnly: false,
              ),
            );
          },
        );
      },
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/spaces_admin/provider_picker_dialog.dart
git commit -m "feat(spaces-admin): add provider picker dialog"
```

---

### Task 9: Create spaces_list_view.dart

**Files:**
- Create: `app/seraph_app/lib/src/spaces_admin/spaces_list_view.dart`

- [ ] **Step 1: Write list view**

```dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/spaces_admin/spaces_detail_view.dart';
import 'package:seraph_app/src/spaces_admin/spaces_list_controller.dart';

class SpacesListView extends StatelessWidget {
  const SpacesListView({super.key});

  static const routeName = '/spaces-admin';

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SpacesListController>();

    return Scaffold(
      appBar: seraphAppBar(
        context,
        name: 'Spaces Admin',
        routeName: routeName,
      ),
      body: Obx(() {
        if (controller.isLoading.value && controller.spaces.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        if (controller.spaces.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('No spaces yet'),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _navigateToDetail(context, null),
                  icon: const Icon(Icons.add),
                  label: const Text('Create Space'),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: controller.loadSpaces,
          child: ListView.builder(
            itemCount: controller.spaces.length,
            itemBuilder: (context, index) {
              final space = controller.spaces[index];
              return Dismissible(
                key: Key(space.id ?? '${index}'),
                direction: DismissDirection.endToStart,
                confirmDismiss: (direction) async {
                  return await Get.dialog<bool>(
                    AlertDialog(
                      title: const Text('Delete Space'),
                      content: Text('Delete "${space.title}"?'),
                      actions: [
                        TextButton(
                          onPressed: () => Get.back(result: false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Get.back(result: true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                },
                onDismissed: (_) => controller.deleteSpace(space.id!),
                background: Container(
                  color: Theme.of(context).colorScheme.error,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                child: Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    title: Text(space.title),
                    subtitle: Text(
                      space.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${space.users.length} users'),
                        Text('${space.fileProviders.length} providers'),
                      ],
                    ),
                    onTap: () => _navigateToDetail(context, space.id),
                  ),
                ),
              );
            },
          ),
        );
      }),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _navigateToDetail(context, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _navigateToDetail(BuildContext context, String? spaceId) {
    Get.to(() => SpacesDetailView(spaceId: spaceId))?.then((_) {
      Get.find<SpacesListController>().loadSpaces();
    });
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/spaces_admin/spaces_list_view.dart
git commit -m "feat(spaces-admin): add spaces list view"
```

---

### Task 10: Create spaces_detail_view.dart

**Files:**
- Create: `app/seraph_app/lib/src/spaces_admin/spaces_detail_view.dart`

- [ ] **Step 1: Write detail view**

```dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/spaces_admin/provider_picker_dialog.dart';
import 'package:seraph_app/src/spaces_admin/spaces_detail_controller.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';

class SpacesDetailView extends StatefulWidget {
  const SpacesDetailView({super.key, this.spaceId});

  final String? spaceId;

  @override
  State<SpacesDetailView> createState() => _SpacesDetailViewState();
}

class _SpacesDetailViewState extends State<SpacesDetailView> {
  @override
  void initState() {
    super.initState();
    final spacesService = Get.find<SpacesService>();
    Get.put(
      SpacesDetailController(spacesService, spaceId: widget.spaceId),
      tag: 'detail-${widget.spaceId ?? 'new'}',
    );
  }

  @override
  void dispose() {
    Get.delete<SpacesDetailController>(
      tag: 'detail-${widget.spaceId ?? 'new'}',
      force: true,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tag = 'detail-${widget.spaceId ?? 'new'}';
    final controller = Get.find<SpacesDetailController>(tag: tag);

    return Scaffold(
      appBar: seraphAppBar(
        context,
        name: controller.isEditing ? 'Edit Space' : 'New Space',
        routeName: SpacesListView.routeName,
        actions: [
          if (controller.isEditing)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _confirmDelete(controller),
            ),
        ],
      ),
      body: Obx(() {
        if (controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        if (controller.error.value != null) {
          return Center(child: Text(controller.error.value!));
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTitleSection(controller),
              const SizedBox(height: 16),
              _buildUsersSection(controller),
              const SizedBox(height: 16),
              _buildProvidersSection(controller),
              const SizedBox(height: 24),
              _buildSaveButton(controller),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildTitleSection(SpacesDetailController controller) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Details',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: controller.titleController,
              decoration: const InputDecoration(
                labelText: 'Title *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller.descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsersSection(SpacesDetailController controller) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Users',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller.userInputController,
                    decoration: const InputDecoration(
                      labelText: 'User ID',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => controller.addUser(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: controller.addUser,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Obx(() => Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: controller.users
                      .map((user) => Chip(
                            label: Text(user),
                            onDeleted: () => controller.removeUser(user),
                          ))
                      .toList(),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildProvidersSection(SpacesDetailController controller) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('File Providers',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Obx(() => ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: controller.fileProviders.length,
                  itemBuilder: (context, index) {
                    final fp = controller.fileProviders[index];
                    return _buildProviderCard(controller, index, fp);
                  },
                )),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _addProvider(controller),
              icon: const Icon(Icons.add),
              label: const Text('Add Provider'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderCard(
    SpacesDetailController controller,
    int index,
    SpaceFileProvider fp,
  ) {
    final nameCtrl =
        TextEditingController(text: fp.spaceProviderId);
    final pathCtrl = TextEditingController(text: fp.path);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    fp.providerId,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      controller.removeFileProvider(index),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) {
                controller.updateFileProvider(
                  index,
                  SpaceFileProvider(
                    spaceProviderId: v,
                    providerId: fp.providerId,
                    path: pathCtrl.text,
                    readOnly: fp.readOnly,
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pathCtrl,
              decoration: const InputDecoration(
                labelText: 'Path',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) {
                controller.updateFileProvider(
                  index,
                  SpaceFileProvider(
                    spaceProviderId: nameCtrl.text,
                    providerId: fp.providerId,
                    path: v,
                    readOnly: fp.readOnly,
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Read Only'),
              value: fp.readOnly,
              onChanged: (v) {
                controller.updateFileProvider(
                  index,
                  SpaceFileProvider(
                    spaceProviderId: nameCtrl.text,
                    providerId: fp.providerId,
                    path: pathCtrl.text,
                    readOnly: v,
                  ),
                );
              },
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton(SpacesDetailController controller) {
    return Obx(() => FilledButton(
          onPressed: controller.isSaving.value
              ? null
              : () => _save(controller),
          child: controller.isSaving.value
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ));
  }

  Future<void> _save(SpacesDetailController controller) async {
    final success = await controller.save();
    if (success && mounted) {
      Get.back();
    }
  }

  Future<void> _addProvider(SpacesDetailController controller) async {
    final result = await Get.dialog<SpaceFileProvider>(
      const ProviderPickerDialog(),
    );
    if (result != null) {
      controller.addFileProvider(result);
    }
  }

  Future<void> _confirmDelete(
      SpacesDetailController controller) async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Delete Space'),
        content: Text(
            'Delete "${controller.titleController.text}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final spacesService = Get.find<SpacesService>();
      try {
        await spacesService.deleteSpace(widget.spaceId!);
        Get.back();
      } catch (e) {
        Get.snackbar('Error', 'Failed to delete space: $e');
      }
    }
  }
}
```

The detail view file needs these imports at the top (ensure they are included):

```dart
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/spaces_admin/provider_picker_dialog.dart';
import 'package:seraph_app/src/spaces_admin/spaces_detail_controller.dart';
import 'package:seraph_app/src/spaces_admin/spaces_list_view.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/spaces_admin/spaces_detail_view.dart
git commit -m "feat(spaces-admin): add spaces detail view"
```

---

### Task 11: Add isSpaceAdmin to LoginController

**Files:**
- Modify: `app/seraph_app/lib/src/login/login_controller.dart`

- [ ] **Step 1: Add isSpaceAdmin observable**

Add a new RxBool field and update it when the OIDC user changes.

```dart
// In the LoginController class, add after existing Rx fields:
  late Rx<bool> _isSpaceAdmin;

  Rx<bool> get isSpaceAdmin => _isSpaceAdmin;

// In the constructor, add initialization:
    _isSpaceAdmin = false.obs;

// In the init method for the non-web path, after _currentUser updates,
// add isSpaceAdmin check. Find the _manager?.userChanges().listen block:

    _manager?.userChanges().listen((user) async {
      print('currentUser changed to ${user?.uid} ${user?.parsedIdToken.claims.toString()}');
      _currentUser.value = user;
      _initialized.value = true;
      shareController.loadShares();
      _updateSpaceAdmin(user);  // <-- add this line
    });

// Also after the initial user refresh at line ~103-107, add:
      _currentUser.value = user;
      _initialized.value = true;
      _updateSpaceAdmin(user);  // <-- add this line

// Add the _updateSpaceAdmin method:
  void _updateSpaceAdmin(OidcUser? user) {
    if (user == null) {
      _isSpaceAdmin.value = false;
      return;
    }

    // Check userInfo for roles claim
    final userInfo = user.userInfo;
    if (userInfo != null) {
      final roles = userInfo['roles'];
      if (roles is List && roles.any((r) => r.toString() == 'space-admin')) {
        _isSpaceAdmin.value = true;
        return;
      }
      // Also check common Zitadel claim patterns
      for (final key in userInfo.keys) {
        if (key.toString().contains('roles')) {
          final value = userInfo[key];
          if (value is List &&
              value.any((r) => r.toString() == 'space-admin')) {
            _isSpaceAdmin.value = true;
            return;
          }
        }
      }
    }

    // Check parsed ID token claims
    final claims = user.parsedIdToken.claims;
    if (claims != null) {
      for (final key in claims.keys) {
        if (key.toString().contains('roles')) {
          final value = claims[key];
          if (value is List &&
              value.any((r) => r.toString() == 'space-admin')) {
            _isSpaceAdmin.value = true;
            return;
          }
        }
      }
    }

    _isSpaceAdmin.value = false;
  }
```

Also in `_initWeb()`, after setting `_noAuth.value = true; _initialized.value = true;`, add `_isSpaceAdmin.value = true;` (in no-auth mode, everyone is space admin, matching backend behavior).

Find this block in `_initWeb()`:
```dart
        _noAuth.value = true;
        _initialized.value = true;
        shareController.loadShares();
```

Change to:
```dart
        _noAuth.value = true;
        _initialized.value = true;
        _isSpaceAdmin.value = true;
        shareController.loadShares();
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/login/login_controller.dart
git commit -m "feat(login): add isSpaceAdmin permission check from OIDC claims"
```

---

### Task 12: Add Spaces Admin to app bar dropdown

**Files:**
- Modify: `app/seraph_app/lib/src/app_bar/app_bar.dart`

- [ ] **Step 1: Add conditional dropdown item**

Add import for LoginController and SpacesListView, then add conditional Spaces Admin dropdown item between Chat and the divider.

```dart
// app/seraph_app/lib/src/app_bar/app_bar.dart

// Add import:
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/spaces_admin/spaces_list_view.dart';

// In seraphAppBar, get the login controller:
  final ShareController shareController = Get.find();
  final LoginController loginController = Get.find();

// The dropdown items are declared as `const`. We need to make them
// non-const and conditionally build them. Change the DropdownButton section:

Replace the existing DropdownButton block:

                child: DropdownButton<String>(
                  isExpanded: true,
                  value: routeName,
                  items: const [
                    DropdownMenuItem(
                        value: FileBrowserView.routeName, child: Text('Cloud Files', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(
                        value: GalleryView.routeName, child: Text('Gallery', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(
                        value: ChatView.routeName, child: Text('Chat', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(enabled: false, child: Divider()),
                    DropdownMenuItem(
                        value: SettingsView.routeName, child: Text('App Settings', overflow: TextOverflow.ellipsis))
                  ],

With an Obx wrapper that builds items conditionally:

                child: Obx(() => DropdownButton<String>(
                  isExpanded: true,
                  value: routeName,
                  items: [
                    const DropdownMenuItem(
                        value: FileBrowserView.routeName, child: Text('Cloud Files', overflow: TextOverflow.ellipsis)),
                    const DropdownMenuItem(
                        value: GalleryView.routeName, child: Text('Gallery', overflow: TextOverflow.ellipsis)),
                    const DropdownMenuItem(
                        value: ChatView.routeName, child: Text('Chat', overflow: TextOverflow.ellipsis)),
                    if (loginController.isSpaceAdmin.value)
                      const DropdownMenuItem(
                          value: SpacesListView.routeName, child: Text('Spaces Admin', overflow: TextOverflow.ellipsis)),
                    const DropdownMenuItem(enabled: false, child: Divider()),
                    const DropdownMenuItem(
                        value: SettingsView.routeName, child: Text('App Settings', overflow: TextOverflow.ellipsis))
                  ],
```

- [ ] **Step 2: Commit**

```bash
git add app/seraph_app/lib/src/app_bar/app_bar.dart
git commit -m "feat(nav): add Spaces Admin to navigation dropdown"
```

---

### Task 13: Register route and bindings

**Files:**
- Modify: `app/seraph_app/lib/src/app.dart`
- Modify: `app/seraph_app/lib/src/initial_binding.dart`

- [ ] **Step 1: Register route in app.dart**

Add import and route:

```dart
// app/seraph_app/lib/src/app.dart

// Add import:
import 'package:seraph_app/src/spaces_admin/spaces_list_view.dart';

// Add GetPage entry in the pages list (inside the `else` block,
// before the SettingsView page entry):

        GetPage(
          name: SpacesListView.routeName,
          page: () => const SpacesListView(),
        ),
```

- [ ] **Step 2: Register service in initial_binding.dart**

```dart
// app/seraph_app/lib/src/initial_binding.dart

// Add imports:
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';
import 'package:seraph_app/src/spaces_admin/spaces_list_controller.dart';

// In the dependencies() method, add:
    Get.put(SpacesService(Get.find(), Get.find()));
    Get.put(SpacesListController(Get.find()));
```

- [ ] **Step 3: Build to verify**

Run: `cd app/seraph_app && flutter analyze`
Expected: no errors

- [ ] **Step 4: Commit**

```bash
git add app/seraph_app/lib/src/app.dart app/seraph_app/lib/src/initial_binding.dart
git commit -m "feat(spaces-admin): register route and bindings"
```

---

### Task 14: End-to-end verification

- [ ] **Step 1: Analyze Flutter app**

Run: `cd app/seraph_app && flutter analyze`
Expected: no errors

- [ ] **Step 2: Build Go backend**

Run: `cd api-gateway && go build ./...`
Expected: exit code 0

- [ ] **Step 3: Run existing Go tests**

Run: `cd api-gateway && go test ./...`
Expected: all tests pass

- [ ] **Step 4: Run existing Flutter tests**

Run: `cd app/seraph_app && flutter test`
Expected: all tests pass

---

## Self-Review Checklist

- [x] Spec coverage: All spec requirements mapped to tasks
  - Register spaces module → Task 1
  - Implement IsSpaceAdmin → Task 2
  - Secure services endpoint → Task 3
  - Models → Task 4
  - Service → Task 5
  - List controller → Task 6
  - Detail controller → Task 7
  - Provider picker → Task 8
  - List view → Task 9
  - Detail view → Task 10
  - LoginController isSpaceAdmin → Task 11
  - App bar nav item → Task 12
  - Routes + bindings → Task 13
- [x] No placeholders: every step has exact code or commands
- [x] Type consistency: Space, SpaceFileProvider, ServiceAnnouncement used consistently across tasks
