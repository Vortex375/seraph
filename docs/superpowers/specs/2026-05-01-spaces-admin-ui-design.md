# Spaces Admin UI — Design Spec

**Date:** 2026-05-01  
**Status:** Draft

## Overview

Add a spaces administration UI to the Flutter app, enabling space admins to create, view, edit, and delete spaces. Each space maps users to file providers (paths within provider services). The UI follows the existing List→Detail pattern used by the Chat feature.

Also implement the backend `IsSpaceAdmin()` realm role check (currently a stub), and secure the services-discovery endpoint behind auth.

## Backend Changes

### 1. Register spaces module in api-gateway/main.go

The `spaces.Module` is defined but never imported/registered. Add it to the `fx.New()` call so the spaces CRUD endpoints become reachable.

File: `api-gateway/main.go`

### 2. Implement IsSpaceAdmin realm role check

The current `oidcAuth.IsSpaceAdmin()` hardcodes `return false` with a `//TODO: role check`. Implement it by checking the OIDC token introspection response for a `space-admin` realm role.

Zitadel typically exposes realm roles via a claim like `urn:zitadel:iam:org:project:roles` or similar in the introspection response. Check the `IntrospectionResponse` struct for roles; if not directly available, check the ID token claims during AuthMiddleware and store the space-admin flag in the context.

The `noAuth.IsSpaceAdmin()` already returns `true` — leave that as-is.

File: `api-gateway/auth/auth.go`

### 3. Secure services endpoint behind space-admin auth

Currently `/api/services` and `/api/services/type/:serviceType` are open (no auth middleware). Add the same `IsSpaceAdmin` check used by the spaces endpoints. If the caller is not a space admin, return 403 Forbidden.

The `servicesHandler.Params` struct needs to include `auth.Auth`. Add it to the fx.In and use `h.auth.IsSpaceAdmin(ctx)` at the top of each handler.

File: `api-gateway/services/services.go`

## Flutter App Changes

### Architecture (following existing Chat pattern)

```
lib/src/spaces_admin/
  spaces_models.dart              # Dart data classes
  spaces_service.dart             # Dio-based API client
  spaces_list_controller.dart     # GetX controller for list
  spaces_list_view.dart           # Master list widget
  spaces_detail_controller.dart   # GetX controller for create/edit
  spaces_detail_view.dart         # Detail/edit form widget
  provider_picker_dialog.dart     # Provider selection dialog
```

### Modified files

| File | Change |
|------|--------|
| `app_bar/app_bar.dart` | Add "Spaces Admin" dropdown item, conditionally visible |
| `app.dart` | Register `/spaces-admin` route |
| `initial_binding.dart` | Register spaces service + controllers |
| `login/login_controller.dart` | Add `isSpaceAdmin` getter derived from OIDC user claims |

### Permission check (client-side)

Instead of a new backend endpoint, extend `LoginController` with an `isSpaceAdmin` Rx getter. Derive it from the `OidcUser`'s claims:

- On the **Flutter side**, check `currentUser.userInfo` for a roles claim. Common Zitadel userinfo claims include a top-level `roles` list. Check if it contains `"space-admin"`. If the claim key differs in production, it can be adjusted later (documented with a comment).

- On the **backend side**, implement `oidcAuth.IsSpaceAdmin()` by inspecting the introspection response. Zitadel's token introspection may include roles in a claim field. Check `IntrospectionResponse` for available role-bearing fields; if not directly present, fall back to checking claims in the ID token parsed during `AuthMiddleware` (store the flag in the request context).

The app bar's dropdown item for "Spaces Admin" is only rendered when `isSpaceAdmin` is true.

### Spaces List View

- Card-based list showing: title, description snippet, user count, provider count
- FloatingActionButton to create new space
- Dismissible cards with delete confirmation dialog
- Tap navigates to detail view (passed space ID or null for create)

### Space Detail / Edit View

- Title field (required, validated)
- Description field (multiline)
- **Users section**: chips with X to remove, text field + Add button
- **File Providers section**: each provider is a card showing:
  - Service instance name/ID (from service discovery, displayed read-only)
  - SpaceProviderId field (user-defined display name, editable)
  - Path field (editable)
  - ReadOnly toggle
  - Remove button
- "Add Provider" button opens `ProviderPickerDialog`
- Save button (PUT or POST)
- Delete button with confirmation dialog (existing spaces only)

### Provider Picker Dialog

- Calls `GET /api/services` to fetch available services
- Shows list of services with their InstanceID and properties
- User selects one → returns to detail form where they fill in SpaceProviderId, Path, ReadOnly
- The selected service's InstanceID becomes the `ProviderId` in the SpaceFileProvider

### API Service (spaces_service.dart)

Uses Dio with Bearer token auth, following `ChatService` pattern:

| Method | Endpoint | Returns |
|--------|----------|---------|
| `listSpaces()` | `GET /api/spaces` | `List<Space>` |
| `getSpace(id)` | `GET /api/spaces/:id` | `Space` |
| `createSpace(space)` | `POST /api/spaces` | `Space` |
| `updateSpace(id, space)` | `PUT /api/spaces/:id` | `Space` |
| `deleteSpace(id)` | `DELETE /api/spaces/:id` | void |
| `listServices()` | `GET /api/services` | `List<ServiceAnnouncement>` |

### Models (spaces_models.dart)

```dart
class Space {
  final String? id;
  final String title;
  final String description;
  final List<String> users;
  final List<SpaceFileProvider> fileProviders;
}

class SpaceFileProvider {
  final String spaceProviderId;
  final String providerId;
  final String path;
  final bool readOnly;
}

class ServiceAnnouncement {
  final String instanceId;
  final String serviceType;
  final Map<String, String> properties;
}
```

### Routes & Navigation

New route: `/spaces-admin` → `SpacesListView`

The spaces admin is a top-level route (like `/chat`, `/settings`), not a sub-route. Space detail uses GetX navigation within the spaces admin flow (e.g., `Get.to(() => SpacesDetailView(spaceId: id))`), consistent with how Chat handles the mobile conversation view.

### Error Handling

- Network errors: `Get.snackbar()` with error message
- Validation errors: inline validation on form fields
- Delete confirmation: `Get.dialog()` with AlertDialog
- Empty list state: centered placeholder text with create CTA

### Edge Cases

- **Create vs Edit**: DetailController accepts optional space ID; if null, it's in create mode (POST instead of PUT, no delete button)
- **Concurrent edits**: Last-write-wins (consistent with current backend behavior)
- **Loading states**: CircularProgressIndicator while fetching
- **Services endpoint failure**: Show error dialog and disable "Add Provider" button
