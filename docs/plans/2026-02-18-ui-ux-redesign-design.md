# PiCamera Pro UI/UX Redesign Design Document

**Date**: 2026-02-18
**Status**: Approved
**Designer**: Claude Sonnet 4.5
**Theme**: Minimal White (Jony Ive-inspired) + Nikon 35Ti Analog Display

---

## Executive Summary

This document outlines a comprehensive redesign of the PiCamera Pro app, addressing:

1. **Editor Tab Overload**: 8 tabs → Icon-based 3x3 grid
2. **Gallery Fragmentation**: Unified view with version management
3. **Status Display**: Nikon 35Ti-inspired analog meter
4. **Design Theme**: Minimal white aesthetic (Apple-inspired)

**Estimated Implementation**: 5-8 hours
**Impact**: High - Significantly improves UX and visual consistency

---

## 1. Architecture & Data Model

### 1.1 Component Hierarchy

```
UnifiedGalleryView (NEW)
├─ PhotoGridView
│  └─ PhotoCell (thumbnail + version badge)
└─ PhotoDetailView (NEW)
   ├─ VersionCarousel (swipe to switch)
   ├─ Nikon35TiMeterView
   └─ ActionBar

PhotoEditorView (MAJOR REFACTOR)
├─ IconGridSelector (NEW)
└─ EditorControlPanel
```

### 1.2 New Core Data Entities

#### PhotoVersion
```swift
class PhotoVersion: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var originalPhotoID: String      // Server filename
    @NSManaged var versionNumber: Int           // 1, 2, 3...
    @NSManaged var imageData: Data              // Edited image
    @NSManaged var thumbnailData: Data?         // Thumbnail
    @NSManaged var settingsJSON: String         // PhotoEditorSettings
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var userRating: Int16
    @NSManaged var isOriginal: Bool             // Original or edited
}
```

#### PhotoGroup
```swift
class PhotoGroup: NSManagedObject {
    @NSManaged var id: String                   // Server filename
    @NSManaged var latestVersion: PhotoVersion  // Relationship
    @NSManaged var versions: Set<PhotoVersion>  // Relationship (1-to-many)
    @NSManaged var serverMetadataJSON: String?
}
```

### 1.3 Data Flow

1. **Initial Load**: Fetch photo list from server → Create PhotoGroup (Original only)
2. **Edit & Save**: Create new PhotoVersion → Update PhotoGroup.latestVersion
3. **Gallery Display**: Show PhotoGroup list (using latestVersion thumbnail)
4. **Detail View**: Display all PhotoGroup.versions (swipe to switch)

### 1.4 Deletion Logic

**Two deletion modes**:

```swift
enum DeleteMode {
    case versionOnly(PhotoVersion)      // Delete edited version only
    case completeFromServer(PhotoGroup) // Delete from server + all versions
}
```

- **Version Only**: Delete local PhotoVersion, update latestVersion
- **Complete**: API call to delete from server + delete all local versions
- **Confirmation**: Show destructive alert for complete deletion

---

## 2. Photo Editor - Icon Grid

### 2.1 Layout

```
┌─────────────────────────┐
│   Preview Image          │
│   (tap to compare)       │
├─────────────────────────┤
│ ┌───┬───┬───┐          │
│ │💡│🎨│✨│ Icon       │
│ │L │C │E │ Grid        │
│ ├───┼───┼───┤          │
│ │🌈│🎭│📊│ (3x3)      │
│ │H │S │T │             │
│ ├───┼───┼───┤          │
│ │✂️│⭕│⭐│            │
│ │CR│R │P │             │
│ └───┴───┴───┘          │
├─────────────────────────┤
│ Selected Category        │
│ Controls (sliders, etc.) │
└─────────────────────────┘
```

### 2.2 Nine Categories

1. **💡 Light** (ライト)
   - Exposure, Contrast, Highlights, Shadows

2. **🎨 Color** (カラー)
   - Temperature, Tint, Saturation, Vibrance, Monochrome, IR Correction

3. **✨ Effects** (エフェクト)
   - Clarity, Texture, Dehaze, Sharpness, Noise Reduction, Vignette, Grain

4. **🌈 HSL** (HSL)
   - 8-color channel adjustment (collapsible)

5. **🎭 Split** (スプリット)
   - Split Toning

6. **📊 Curve** (カーブ)
   - Tone Curve (Master/RGB)

7. **✂️ Crop** (切り抜き)
   - Cropping

8. **⭕ Radial** (ラジアル)
   - Radial Mask

9. **⭐ Presets** (プリセット)
   - Preset save/load

### 2.3 Design Specifications

**Icon Grid**:
- Grid: 3x3, equal spacing (16pt)
- Icon size: 48pt × 48pt
- SF Symbols, 24pt icon size
- Selected state: Ultra-thin black border (0.5pt) + subtle shadow
- Unselected: Gray (#8E8E93)

**Animations**:
- Icon tap: 0.15s spring animation
- Panel switch: 0.2s fade
- Preview update: 150ms debounce

**Typography**:
- Icon label: SF Pro Text, 9pt, Medium
- Value display: SF Mono, 12pt, Regular
- Section title: SF Pro Display, 11pt, Semibold

---

## 3. Unified Gallery View

### 3.1 Gallery Grid

**PhotoCell Display**:
```
┌─────────────┐
│             │
│  Thumbnail   │ ← latestVersion image
│             │
│ ┌─────────┐ │
│ │📷 v3    │ │ ← Version badge (bottom-right)
│ └─────────┘ │
└─────────────┘
```

**Version Badge**:
- Original only: No badge
- With edits: `📷 v2`, `📷 v3`, etc.
- Semi-transparent background, white text
- Always shows latest version thumbnail

### 3.2 Detail View (PhotoDetailView)

**Layout**:
```
┌───────────────────────────┐
│ < Back    📷 3/3    ⋯     │ ← Navigation
├───────────────────────────┤
│                           │
│    Main Image             │
│    (swipe left/right      │
│     to switch versions)   │
│                           │
├───────────────────────────┤
│ ○ ● ○                    │ ← Version indicator
├───────────────────────────┤
│ Version 2                 │ ← Version name
│ ISO 400 • 1/250s • f/2.8 │ ← Metadata
│ ⭐⭐⭐⭐⭐ (5.0)          │ ← Rating
├───────────────────────────┤
│ [Edit] [Delete] [Share]   │ ← Actions
└───────────────────────────┘
```

### 3.3 Version Management

**Swipe Switching**:
- Left swipe: Newer version
- Right swipe: Older version
- Spring animation (0.3s)

**Display Order**:
- Original → v1 → v2 → v3...
- Indicator shows current position

**Version Info**:
- Original: Server metadata (ISO, SS, WB, etc.)
- Edited: Edit settings summary (Exposure +0.5, Saturation +20%, etc.)

**Actions**:
- **Edit**: Open PhotoEditorView (using current version as base)
- **Delete**:
  - Version only: Delete edited version (Original protected)
  - Complete: Delete from server + all versions (with confirmation)
- **Share**: Standard ShareSheet

### 3.4 Delete Action Sheet

```
┌─────────────────────────┐
│ Delete this photo        │
├─────────────────────────┤
│ 🗑️ Delete version only │ ← Delete v2 only
│ (Keep original)          │
├─────────────────────────┤
│ ⚠️ Delete from server   │ ← Server + all versions
│ (Cannot restore)         │
├─────────────────────────┤
│ Cancel                   │
└─────────────────────────┘
```

---

## 4. Nikon 35Ti Analog Meter

### 4.1 Design Concept

Recreate the iconic Nikon 35Ti analog display panel in modern SwiftUI.

**Reference**: Nikon 35Ti top panel with 4 needles:
1. Left large needle: Aperture (f-stop) - 180° scale
2. Right large needle: Shutter speed - 180° scale
3. Center short needle: Exposure compensation - 70° scale
4. Center small needle: ISO - 360° scale (full rotation)

### 4.2 Layout

```
┌─────────────────────────────────────┐
│  ┌───────────────────────────────┐  │
│  │ 2.8  4  5.6  8  11  16  22    │  │ ← f-stop scale
│  │   ┌─────────────────────────┐ │  │
│  │ 3 │    -2 -1  0 +1 +2       │ P │ ← EV scale
│  │ 7 │      ↑ (short)          │ 10│
│  │10 │  ↖       ⊙       ↗     │ 20│ ← Needles
│  │   │ (f#)  (ISO)  (SS)       │ 30│
│  │2.6│                         │   │
│  │0.7│    Nikon 35Ti           │ 2 │
│  │   └─────────────────────────┘   │
│  │     16   22        ━   ●   ━   │
│  └───────────────────────────────┘  │
│                                     │
│  F2.8 • 1/250 • ISO400 • +0.3EV    │ ← Digital readout
└─────────────────────────────────────┘
```

### 4.3 Implementation

**Capsule Panel**:
- Size: 320pt × 160pt
- Border: 1pt, gray (#D1D1D6)
- Background: Light `#FAFAFA` / Dark `#1C1C1E`
- Shape: `.capsule`

**Scales**:
- Top: f-stops `2.8  4  5.6  8  11  16  22`
- Left: Shutter speeds `3  7  10  2.6  1.3  0.7`
- Right: Program modes `P  10  20  30`
- Center top: EV compensation `-2  -1  0  +1  +2`
- Font: SF Mono, 8-9pt, Medium/Regular

**Four Needles**:

```swift
struct Needle: View {
    let length: CGFloat
    let width: CGFloat
    let color: Color
    let angle: Double

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle))
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: angle)
    }
}
```

**Needle Specifications**:
1. Left (Aperture): 50pt long, 2pt wide, primary color, -90° to +90°
2. Right (Shutter): 50pt long, 2pt wide, primary color, -90° to +90°
3. Center Top (EV): 30pt long, 1.5pt wide, orange, -35° to +35°
4. Center (ISO): 20pt long, 1pt wide, blue, 0° to 360°

**Angle Calculations**:
- Aperture: `log2(aperture / 2.8) / log2(22 / 2.8) * 180 - 90`
- Shutter: `log2(shutterμs / 125) / 13 * 180 - 90`
- EV: `exposureComp * 17.5`
- ISO: `log2(iso / 100) / 6 * 360`

**Digital Readout** (below meter):
```swift
HStack(spacing: 8) {
    Text("F\(aperture, specifier: "%.1f")")
    Text("•")
    Text(shutterLabel)  // "1/250"
    Text("•")
    Text("ISO\(iso)")
    Text("•")
    Text(String(format: "%+.1fEV", ev))
}
.font(.system(size: 12, weight: .medium, design: .monospaced))
```

**Animation**:
- Value change: 0.3s fade
- Meter load: Pulse animation

---

## 5. Global Minimal Theme

### 5.1 Color System

**Light Mode**:
```swift
struct MinimalTheme {
    // Backgrounds
    static let background = Color(hex: "#FAFAFA")      // Very light gray
    static let surface = Color(hex: "#FFFFFF")         // Pure white
    static let surfaceVariant = Color(hex: "#F5F5F5")  // Card background

    // Text
    static let primary = Color(hex: "#1C1C1E")         // Almost black
    static let secondary = Color(hex: "#8E8E93")       // Gray
    static let tertiary = Color(hex: "#C7C7CC")        // Light gray

    // Accent
    static let accent = Color(hex: "#007AFF")          // System blue
    static let destructive = Color(hex: "#FF3B30")     // System red

    // Dividers
    static let divider = Color(hex: "#E5E5EA")
}
```

**Dark Mode**: Auto-inverted
- Background: `#000000`
- Surface: `#1C1C1E`
- Primary text: `#F5F5F7`

### 5.2 Typography System

```swift
struct MinimalTypography {
    // Display
    static let displayLarge = Font.system(size: 34, weight: .bold)

    // Headlines
    static let headlineLarge = Font.system(size: 22, weight: .semibold)
    static let headlineMedium = Font.system(size: 17, weight: .semibold)

    // Body
    static let bodyLarge = Font.system(size: 17, weight: .regular)
    static let bodyMedium = Font.system(size: 15, weight: .regular)

    // Captions
    static let caption = Font.system(size: 12, weight: .regular)
    static let captionMono = Font.system(size: 12, weight: .regular, design: .monospaced)

    // Labels
    static let labelSmall = Font.system(size: 11, weight: .medium)
}
```

### 5.3 Spacing System

```swift
struct MinimalSpacing {
    static let xs: CGFloat = 4      // Extra small
    static let sm: CGFloat = 8      // Small
    static let md: CGFloat = 16     // Medium (standard)
    static let lg: CGFloat = 24     // Large
    static let xl: CGFloat = 32     // Extra large
    static let xxl: CGFloat = 48    // Extra extra large
}
```

### 5.4 Component Styles

**Minimal Card**:
```swift
struct MinimalCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(MinimalSpacing.md)
            .background(MinimalTheme.surface)
            .cornerRadius(12)
            .shadow(
                color: Color.black.opacity(0.03),
                radius: 8,
                x: 0,
                y: 2
            )
    }
}

extension View {
    func minimalCard() -> some View {
        modifier(MinimalCard())
    }
}
```

**Minimal Button**:
```swift
struct MinimalButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MinimalTypography.bodyMedium)
            .foregroundColor(MinimalTheme.accent)
            .padding(.horizontal, MinimalSpacing.md)
            .padding(.vertical, MinimalSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MinimalTheme.divider, lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2), value: configuration.isPressed)
    }
}
```

### 5.5 Animation Principles

**Timing**:
- UI transitions: 0.2s (easeInOut)
- Data updates: 0.15s (linear)
- Interactions: 0.3s (spring)

**Easing**:
```swift
static let standardEase = Animation.easeInOut(duration: 0.2)
static let springEase = Animation.spring(response: 0.3, dampingFraction: 0.7)
static let quickFade = Animation.linear(duration: 0.15)
```

### 5.6 Application Scope

**Apply to all screens**:
- ContentView → Minimalize controls
- PhotoEditorView → Icon grid + minimal controls
- UnifiedGalleryView → Simple grid
- CameraStatusView → Nikon 35Ti meter + minimal text
- Settings → List to minimal cards

---

## 6. Implementation Priority

### Phase 1: Foundation (2h)
1. Create new Core Data entities (PhotoVersion, PhotoGroup)
2. Implement MinimalTheme system
3. Create base components (MinimalCard, MinimalButton)

### Phase 2: Gallery (2h)
1. Build UnifiedGalleryView with PhotoGroup
2. Implement PhotoDetailView with version carousel
3. Add delete functionality (version-only + complete)

### Phase 3: Editor (2h)
1. Create IconGridSelector (3x3)
2. Refactor PhotoEditorView to use grid
3. Migrate existing controls to minimal style

### Phase 4: Status (1h)
1. Implement Nikon35TiMeterView with 4 needles
2. Replace CameraStatusView
3. Add digital readout

### Phase 5: Polish (1h)
1. Apply theme to all remaining screens
2. Test animations and transitions
3. Fix edge cases

**Total Estimated Time**: 8 hours

---

## 7. Success Metrics

- ✅ Editor tabs reduced from 8 to 9 icons (but visually clearer)
- ✅ Gallery unified with version management
- ✅ Nikon 35Ti meter with 4 animated needles
- ✅ Consistent minimal white theme across all screens
- ✅ Smooth animations (60fps)
- ✅ Original photos deletable from server

---

## 8. Technical Considerations

### 8.1 Performance
- Thumbnail generation: Async with caching
- Version switching: Preload adjacent versions
- Needle animations: GPU-accelerated transforms

### 8.2 Data Migration
- Migrate existing EditedPhoto to PhotoVersion
- Create PhotoGroup for each unique filename
- Preserve user ratings and metadata

### 8.3 Backward Compatibility
- Keep EditedPhoto entity for migration
- Gradual migration on first launch
- Fallback to server fetch if local missing

---

## Appendix A: Design References

1. **Nikon 35Ti**: Top panel analog display
2. **Apple Design**: Minimal white aesthetic, SF Symbols
3. **Ferrari Luce**: Luxury feel, attention to detail
4. **Lightroom**: Icon-based tool selection
5. **Apple Photos**: Version management inspiration

---

**End of Design Document**

*Approved by user on 2026-02-18*
