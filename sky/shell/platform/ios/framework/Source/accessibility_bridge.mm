// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "sky/shell/platform/ios/framework/Source/accessibility_bridge.h"

#import <UIKit/UIKit.h>

#include "mojo/public/cpp/application/connect.h"

namespace {

static const uint32_t RootNodeId = 0;

// Contains better abstractions than the raw Mojo data structure
struct Geometry {
  Geometry& operator=(const semantics::SemanticGeometryPtr& other) {
    if (!other->transform.is_null()) {
      transform.setColMajorf(other->transform.data());
    }
    rect.setXYWH(other->left, other->top, other->width, other->height);
    return *this;
  }

  SkMatrix44 transform =
      SkMatrix44(SkMatrix44::Identity_Constructor::kIdentity_Constructor);
  SkRect rect;
};

}  // anonymous namespace

@implementation AccessibilityNode {
  sky::shell::AccessibilityBridge* _bridge;

  semantics::SemanticFlagsPtr _flags;
  semantics::SemanticStringsPtr _strings;
  Geometry _geometry;
}

#pragma mark - Override base class designated initializers

// Method declared as unavailable in the interface
- (instancetype)init {
  [self release];
  [super doesNotRecognizeSelector:_cmd];
  return nil;
}

#pragma mark - Designated initializers

- (instancetype)initWithBridge:(sky::shell::AccessibilityBridge*)bridge
                           uid:(uint32_t)uid {
  DCHECK(bridge != nil) << "bridge must be set";
  DCHECK(uid >= RootNodeId);
  self = [super init];

  if (self) {
    _bridge = bridge;
    _uid = uid;
  }

  return self;
}

#pragma mark - Semantics node methods

- (void)update:(const semantics::SemanticsNodePtr&)mojoNode {
  DCHECK(_uid == mojoNode->id);

  if (!mojoNode->flags.is_null()) {
    _flags = mojoNode->flags.Pass();
  }

  if (!mojoNode->strings.is_null()) {
    _strings = mojoNode->strings.Pass();
  }

  if (!mojoNode->geometry.is_null()) {
    _geometry = mojoNode->geometry;
  }

  if (!mojoNode->children.is_null()) {
    // Mark existing children as orphans
    NSArray* oldChildren = _children;
    for (AccessibilityNode* child in oldChildren) {
      DCHECK(child->_parent != nil);
      child->_parent = nil;
    }

    // Set the new list of children
    NSMutableArray* children = [[NSMutableArray alloc] init];
    _children = children;
    for (const semantics::SemanticsNodePtr& mojoChild : mojoNode->children) {
      AccessibilityNode* child = _bridge->UpdateNode(mojoChild);
      child->_parent = self;
      [children insertObject:child atIndex:0];
    }

    // Remove those children that are still marked as orphans
    for (AccessibilityNode* child in oldChildren) {
      if (child->_parent == nil) {
        _bridge->RemoveNode(child);
      }
    }
    [oldChildren release];
  }
}

- (void)remove {
  _parent = nil;
  _bridge->RemoveNode(self);
}

#pragma mark - UIAccessibility overrides

- (BOOL)isAccessibilityElement {
  // Note: hit detection will only apply to elements that report
  // -isAccessibilityElement of YES. The framework will continue scanning the
  // entire element tree looking for such a hit.
  return (_flags->canBeTapped || _children.count == 0);
}

- (NSString*)accessibilityLabel {
  return (_strings.is_null() || _strings->label.get().empty())
             ? nil
             : @(_strings->label.data());
}

- (UIAccessibilityTraits)accessibilityTraits {
  // TODO(tvolkert): We need more semantic info in the mojom definition
  // in order to distinguish buttons, links, sliders, etc.
  return _flags->canBeTapped ? UIAccessibilityTraitButton
                             : UIAccessibilityTraitNone;
}

- (CGRect)accessibilityFrame {
  SkMatrix44 globalTransform = _geometry.transform;
  for (AccessibilityNode* parent = _parent; parent; parent = parent.parent) {
    globalTransform = globalTransform * parent->_geometry.transform;
  }

  SkPoint quad[4];
  _geometry.rect.toQuad(quad);
  for (auto& point : quad) {
    SkScalar vector[4] = {point.x(), point.y(), 0, 1};
    globalTransform.mapScalars(vector);
    point.set(vector[0], vector[1]);
  }
  SkRect rect;
  rect.set(quad, 4);

  auto result = CGRectMake(rect.x(), rect.y(), rect.width(), rect.height());
  return UIAccessibilityConvertFrameToScreenCoordinates(result,
                                                        _bridge->view());
}

#pragma mark - UIAccessibilityElement protocol

- (id)accessibilityContainer {
  return (_uid == RootNodeId) ? _bridge->view() : _parent;
}

#pragma mark - UIAccessibilityContainer overrides

- (NSInteger)accessibilityElementCount {
  return _children.count;
}

- (nullable id)accessibilityElementAtIndex:(NSInteger)index {
  return (index < 0 || index >= (NSInteger)_children.count ? nil
                                                           : _children[index]);
}

- (NSInteger)indexOfAccessibilityElement:(id)element {
  return (_children == nil) ? NSNotFound : [_children indexOfObject:element];
}

#pragma mark - UIAccessibilityAction overrides

- (BOOL)accessibilityActivate {
  // TODO(tvolkert): Implement
  return NO;
}

- (void)accessibilityIncrement {
  // TODO(tvolkert): Implement
}

- (void)accessibilityDecrement {
  // TODO(tvolkert): Implement
}

- (BOOL)accessibilityScroll:(UIAccessibilityScrollDirection)direction {
  BOOL canBeScrolled = NO;
  switch (direction) {
    case UIAccessibilityScrollDirectionRight:
    case UIAccessibilityScrollDirectionLeft:
      canBeScrolled = _flags->canBeScrolledHorizontally;
      break;
    case UIAccessibilityScrollDirectionUp:
    case UIAccessibilityScrollDirectionDown:
      canBeScrolled = _flags->canBeScrolledVertically;
      break;
    default:
      // Note: page turning of reading content is not currently supported
      // (UIAccessibilityScrollDirectionNext,
      //  UIAccessibilityScrollDirectionPrevious)
      canBeScrolled = NO;
  }

  if (!canBeScrolled) {
    return NO;
  }

  switch (direction) {
    case UIAccessibilityScrollDirectionRight:
      _bridge->server()->ScrollRight(_uid);
      break;
    case UIAccessibilityScrollDirectionLeft:
      _bridge->server()->ScrollLeft(_uid);
      break;
    case UIAccessibilityScrollDirectionUp:
      _bridge->server()->ScrollDown(_uid);
      break;
    case UIAccessibilityScrollDirectionDown:
      _bridge->server()->ScrollUp(_uid);
      break;
    default:
      DCHECK(false) << "Unsupported scroll direction: " << direction;
  }

  // TODO(tvolkert): provide meaningful string (e.g. "page 2 of 5")
  UIAccessibilityPostNotification(UIAccessibilityPageScrolledNotification, nil);
  return YES;
}

- (BOOL)accessibilityPerformEscape {
  // TODO(tvolkert): Implement
  return NO;
}

- (BOOL)accessibilityPerformMagicTap {
  // TODO(tvolkert): Implement
  return NO;
}

#pragma mark - Misc

- (void)dealloc {
  [_children release];
  [super dealloc];
}

@end

#pragma mark - AccessibilityBridge impl

namespace sky {
namespace shell {

AccessibilityBridge::AccessibilityBridge(FlutterView* view,
                                         mojo::ServiceProvider* serviceProvider)
    : view_(view), binding_(this), weak_factory_(this) {
  mojo::ConnectToService(serviceProvider, mojo::GetProxy(&semantics_server_));
  mojo::InterfaceHandle<semantics::SemanticsListener> listener;
  binding_.Bind(&listener);
  semantics_server_->AddSemanticsListener(listener.Pass());

  nodes_ = [[NSMutableDictionary alloc] init];
}

void AccessibilityBridge::UpdateSemanticsTree(
    mojo::Array<semantics::SemanticsNodePtr> mojoNodes) {
  for (const semantics::SemanticsNodePtr& mojoNode : mojoNodes) {
    auto node = UpdateNode(mojoNode);
    if (mojoNode->id == RootNodeId && view_.accessibilityElements == nil) {
      view_.accessibilityElements = @[ node ];
    }
  }
  DCHECK(view_.accessibilityElements != nil);

  UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,
                                  nil);
}

base::WeakPtr<AccessibilityBridge> AccessibilityBridge::AsWeakPtr() {
  return weak_factory_.GetWeakPtr();
}

AccessibilityNode* AccessibilityBridge::UpdateNode(
    const semantics::SemanticsNodePtr& mojoNode) {
  AccessibilityNode* node = nodes_[@(mojoNode->id)];
  if (node == nil) {
    node = [[AccessibilityNode alloc] initWithBridge:this uid:mojoNode->id];
    DCHECK(nodes_ != nil);
    nodes_[@(mojoNode->id)] = node;
    [node release];
  }
  [node update:mojoNode];
  return node;
}

void AccessibilityBridge::RemoveNode(AccessibilityNode* node) {
  [node retain];
  DCHECK(nodes_[@(node.uid)] != nil);
  DCHECK(nodes_[@(node.uid)].parent == nil);
  [nodes_ removeObjectForKey:@(node.uid)];
  for (AccessibilityNode* child in node.children) {
    [child remove];
  }
  [node release];
}

AccessibilityBridge::~AccessibilityBridge() {
  [nodes_ release];
}

}  // namespace shell
}  // namespace sky
