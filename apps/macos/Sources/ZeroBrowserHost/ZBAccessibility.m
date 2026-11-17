#import "ZBAccessibility.h"

// Chromium's accessibility roles → AppKit's (CEF's own Mac bridge, tests/shared/browser/osr_accessibility_node_mac.mm,
// with headings and the web area as Safari shows them).
static NSString *Role(NSString *role) {
  static NSDictionary<NSString *, NSString *> *map;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = @{
      @"rootWebArea": @"AXWebArea", @"webArea": @"AXWebArea", @"heading": @"AXHeading",
      @"annotation": NSAccessibilityUnknownRole, @"busyIndicator": NSAccessibilityBusyIndicatorRole,
      @"button": NSAccessibilityButtonRole, @"buttonDropDown": NSAccessibilityButtonRole, @"canvas": NSAccessibilityImageRole,
      @"checkBox": NSAccessibilityCheckBoxRole, @"colorWell": NSAccessibilityColorWellRole, @"column": NSAccessibilityColumnRole,
      @"comboBox": NSAccessibilityComboBoxRole, @"descriptionList": NSAccessibilityListRole, @"directory": NSAccessibilityListRole,
      @"disclosureTriangle": NSAccessibilityDisclosureTriangleRole, @"imageMapLink": NSAccessibilityLinkRole,
      @"image": NSAccessibilityImageRole, @"link": NSAccessibilityLinkRole, @"listBoxOption": NSAccessibilityStaticTextRole,
      @"listBox": NSAccessibilityListRole, @"list": NSAccessibilityListRole, @"menu": NSAccessibilityMenuRole,
      @"menuBar": NSAccessibilityMenuBarRole, @"menuButton": NSAccessibilityButtonRole, @"menuItem": NSAccessibilityMenuItemRole,
      @"menuItemCheckBox": NSAccessibilityMenuItemRole, @"menuItemRadio": NSAccessibilityMenuItemRole,
      @"menuListOption": NSAccessibilityMenuItemRole, @"meter": NSAccessibilityProgressIndicatorRole,
      @"outline": NSAccessibilityOutlineRole, @"popUpButton": NSAccessibilityPopUpButtonRole,
      @"progressIndicator": NSAccessibilityProgressIndicatorRole, @"radioButton": NSAccessibilityRadioButtonRole,
      @"row": NSAccessibilityRowRole, @"ruler": NSAccessibilityRulerRole, @"scrollBar": NSAccessibilityScrollBarRole,
      @"searchBox": NSAccessibilityTextFieldRole, @"slider": NSAccessibilitySliderRole,
      @"sliderThumb": NSAccessibilityValueIndicatorRole, @"spinButton": NSAccessibilityIncrementorRole,
      @"splitter": NSAccessibilitySplitterRole, @"staticText": NSAccessibilityStaticTextRole,
      @"switch": NSAccessibilityCheckBoxRole, @"tab": NSAccessibilityRadioButtonRole, @"table": NSAccessibilityTableRole,
      @"textField": NSAccessibilityTextFieldRole, @"textFieldWithComboBox": NSAccessibilityComboBoxRole,
      @"toggleButton": NSAccessibilityCheckBoxRole, @"toolbar": NSAccessibilityToolbarRole, @"treeGrid": NSAccessibilityTableRole,
      @"treeItem": NSAccessibilityRowRole, @"tree": NSAccessibilityOutlineRole, @"window": NSAccessibilityWindowRole,
    };
  });
  return map[role] ?: NSAccessibilityGroupRole;
}

static int Int(id v) { return [v isKindOfClass:NSString.class] ? [v intValue] : [v respondsToSelector:@selector(intValue)] ? [v intValue] : 0; }

@interface ZBAXNode ()
@property (nonatomic, weak) ZBAXTree *tree;
@property (nonatomic) int nodeId, offsetContainer, scrollX, scrollY;
@property (nonatomic, copy) NSString *chromeRole, *name, *valueText, *details;
@property (nonatomic) CGRect location;
@property (nonatomic, copy) NSArray<NSNumber *> *childIds;
@property (nonatomic, copy) NSDictionary *attributes;
@property (nonatomic, copy) id states;  // Chromium's states: a list ("protected", "focusable"…)
@end

@implementation ZBAXTree {
  NSMutableDictionary<NSNumber *, ZBAXNode *> *_nodes;
  int _root, _focus;
}

- (instancetype)init {
  if ((self = [super init])) {
    _nodes = [NSMutableDictionary dictionary];
    _root = -1;
    _focus = -1;
  }
  return self;
}

- (ZBAXNode *)root { return _nodes[@(_root)]; }
- (ZBAXNode *)focused { return _nodes[@(_focus)]; }
- (ZBAXNode *)node:(int)nodeId { return _nodes[@(nodeId)]; }
- (NSUInteger)count { return _nodes.count; }

- (void)remove:(int)nodeId {
  ZBAXNode *n = _nodes[@(nodeId)];
  if (!n) return;
  for (NSNumber *c in n.childIds) [self remove:c.intValue];
  [_nodes removeObjectForKey:@(nodeId)];
}

/// One OnAccessibilityTreeChange: {ax_tree_id, updates: [{node_id_to_clear, tree_data, nodes: [...]}]}. Only the
/// page's own tree (no iframes' trees yet).
- (void)apply:(NSString *)json {
  NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![d isKindOfClass:NSDictionary.class]) return;
  NSString *tree = d[@"ax_tree_id"];
  // A new document in the tab (it navigated) is a new tree: the page's is the one with no parent (an iframe's has one).
  if (_treeId && ![tree isEqual:_treeId]) {
    NSDictionary *data = [d[@"updates"] firstObject][@"tree_data"];
    NSString *parent = data[@"parent_tree_id"];
    if (data && !([parent isKindOfClass:NSString.class] && parent.length)) {
      [_nodes removeAllObjects];
      _root = -1;
      _focus = -1;
      _url = nil;
      _treeId = nil;
    }
  }
  if (!_treeId) _treeId = tree;
  if (![tree isEqual:_treeId]) return;
  for (NSDictionary *u in d[@"updates"]) {
    if (u[@"node_id_to_clear"]) [self remove:Int(u[@"node_id_to_clear"])];
    if ([u[@"has_tree_data"] boolValue]) {
      NSDictionary *data = u[@"tree_data"];
      if (data[@"focus_id"]) _focus = Int(data[@"focus_id"]);
      if ([data[@"url"] isKindOfClass:NSString.class]) _url = [data[@"url"] copy];
    }
    if (u[@"root_id"]) _root = Int(u[@"root_id"]);
    for (NSDictionary *n in u[@"nodes"]) {
      int nid = Int(n[@"id"]);
      ZBAXNode *node = _nodes[@(nid)];
      if (!node) {
        node = [ZBAXNode new];
        node.tree = self;
        node.nodeId = nid;
        _nodes[@(nid)] = node;
      }
      if (n[@"role"]) node.chromeRole = n[@"role"];
      if (n[@"state"]) node.states = n[@"state"];
      if (n[@"child_ids"]) {
        NSMutableArray *ids = [NSMutableArray array];
        for (id c in n[@"child_ids"]) [ids addObject:@(Int(c))];
        node.childIds = ids;
      }
      NSDictionary *loc = n[@"location"] ?: n[@"bounds"];
      if (loc) node.location = CGRectMake([loc[@"x"] doubleValue], [loc[@"y"] doubleValue], [loc[@"width"] doubleValue], [loc[@"height"] doubleValue]);
      if (n[@"offset_container_id"]) node.offsetContainer = Int(n[@"offset_container_id"]);
      NSDictionary *a = n[@"attributes"];
      if ([a isKindOfClass:NSDictionary.class]) {
        node.attributes = a;
        node.name = a[@"name"];
        node.valueText = a[@"value"];
        node.details = a[@"description"];
        node.scrollX = Int(a[@"scrollX"]);
        node.scrollY = Int(a[@"scrollY"]);
      }
      if ([node.chromeRole isEqual:@"rootWebArea"] && _root < 0) _root = nid;
    }
  }
  // Parents follow children lists.
  for (ZBAXNode *n in _nodes.allValues)
    for (NSNumber *c in n.childIds) [_nodes[c] setValue:n forKey:@"axParent"];
}

/// OnAccessibilityLocationChange: [{ax_tree_id, id, new_location: {bounds: {...}, offset_container_id}}].
- (void)move:(NSString *)json {
  NSArray *list = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![list isKindOfClass:NSArray.class]) return;
  for (NSDictionary *c in list) {
    if (![c[@"ax_tree_id"] isEqual:_treeId]) continue;
    ZBAXNode *n = _nodes[@(Int(c[@"id"]))];
    NSDictionary *loc = c[@"new_location"][@"bounds"];
    if (n && loc) n.location = CGRectMake([loc[@"x"] doubleValue], [loc[@"y"] doubleValue], [loc[@"width"] doubleValue], [loc[@"height"] doubleValue]);
    if (n && c[@"new_location"][@"offset_container_id"]) n.offsetContainer = Int(c[@"new_location"][@"offset_container_id"]);
  }
}
@end

@interface ZBAXNode (Pixels)
- (CGRect)pixelRect;
@end

@implementation ZBAXNode {
  __weak ZBAXNode *_axParent;
}

- (void)setAxParent:(ZBAXNode *)parent { _axParent = parent; }

/// Where it is in the page view's points. Chromium gives device pixels (2 to a point on Retina).
- (CGRect)pageRect {
  CGFloat scale = self.tree.view.window.backingScaleFactor ?: 2;
  CGRect r = self.pixelRect;
  return CGRectMake(r.origin.x / scale, r.origin.y / scale, r.size.width / scale, r.size.height / scale);
}

/// Its location in its offset container's, less its own scroll, in device pixels.
- (CGRect)pixelRect {
  CGRect r = self.location;
  r.origin.x -= self.scrollX;
  r.origin.y -= self.scrollY;
  ZBAXNode *container = [self.tree node:self.offsetContainer];
  if (container && container != self) {
    CGRect c = container.pixelRect;
    r.origin.x += c.origin.x;
    r.origin.y += c.origin.y;
  }
  return r;
}

- (BOOL)isAccessibilityElement { return ![self.chromeRole isEqual:@"ignored"] && ![self.chromeRole isEqual:@"none"]; }
- (NSAccessibilityRole)accessibilityRole { return Role(self.chromeRole); }
- (NSString *)accessibilityRoleDescription {
  if ([self.chromeRole isEqual:@"heading"]) return @"heading";
  if ([self.chromeRole isEqual:@"rootWebArea"]) return @"HTML content";
  return NSAccessibilityRoleDescription(self.accessibilityRole, nil);
}
- (NSString *)accessibilityLabel { return self.name; }
- (NSString *)accessibilityTitle { return self.name; }
- (id)accessibilityValue {
  if ([self.chromeRole isEqual:@"checkBox"] || [self.chromeRole isEqual:@"switch"]) return @([self.attributes[@"checkedState"] isEqual:@"true"] || [self.attributes[@"checkedState"] isEqual:@"mixed"] ? 1 : 0);
  return self.valueText;
}
- (NSString *)accessibilityHelp { return self.details; }
- (BOOL)isAccessibilityFocused { return self.tree.focused == self; }

// What Safari's web areas and fields give assistive apps, and 1Password's Universal Autofill reads: the page's address
// on the web area, password fields as secure, placeholders, and the DOM's id and classes.
- (BOOL)isWebArea { return [self.chromeRole isEqual:@"rootWebArea"]; }
- (BOOL)isTextField { return [Role(self.chromeRole) isEqual:NSAccessibilityTextFieldRole]; }
- (BOOL)isSecure {
  id state = self.states ?: self.attributes[@"state"];
  return [state isKindOfClass:NSArray.class] ? [state containsObject:@"protected"] : [state isKindOfClass:NSString.class] && [state containsString:@"protected"];
}
- (NSURL *)accessibilityURL {
  if (!self.isWebArea) return nil;
  NSString *url = self.tree.url ?: self.attributes[@"url"];
  return url.length ? [NSURL URLWithString:url] : nil;
}
- (NSAccessibilitySubrole)accessibilitySubrole { return self.isSecure ? NSAccessibilitySecureTextFieldSubrole : nil; }
// A placeholder that names the field (no label) is in its name only, as Chromium's own Mac tree reads it.
- (NSString *)accessibilityPlaceholderValue {
  return self.attributes[@"placeholder"] ?: ([self.attributes[@"nameFrom"] isEqual:@"placeholder"] ? self.name : nil);
}
- (NSArray *)accessibilityChildrenInNavigationOrder { return self.accessibilityChildren; }
- (NSArray<NSAccessibilityAttributeName> *)accessibilityAttributeNames {
  NSMutableArray *names = [[super accessibilityAttributeNames] mutableCopy] ?: [NSMutableArray array];
  for (NSString *name in @[@"AXDOMIdentifier", @"AXDOMClassList", NSAccessibilityURLAttribute, NSAccessibilityPlaceholderValueAttribute])
    if (![names containsObject:name]) [names addObject:name];
  return names;
}
- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)name {
  if ([name isEqual:@"AXDOMIdentifier"]) return self.attributes[@"htmlId"];
  if ([name isEqual:@"AXDOMClassList"]) {
    NSString *classes = self.attributes[@"className"];
    return classes.length ? [classes componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : nil;
  }
  return [super accessibilityAttributeValue:name];
}
// Set as typing sets them: focus by a click, a value by replacing the field's text with typed text.
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
  if (selector == @selector(setAccessibilityValue:) || selector == @selector(setAccessibilityFocused:)) return self.isTextField && self.tree.fill;
  return [super isAccessibilitySelectorAllowed:selector];
}
- (void)setAccessibilityFocused:(BOOL)focused {
  if (focused && self.isTextField && self.tree.fill) self.tree.fill(self, nil);
}
- (void)setAccessibilityValue:(id)value {
  if (self.isTextField && self.tree.fill && [value isKindOfClass:NSString.class]) self.tree.fill(self, value);
}

- (NSArray *)accessibilityChildren {
  // A control's text and a text run's boxes are part of it, as in Safari: VoiceOver reads them from the control.
  static NSSet *leaves;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    leaves = [NSSet setWithArray:@[@"button", @"link", @"checkBox", @"radioButton", @"textField", @"searchBox", @"image",
                                   @"staticText", @"popUpButton", @"comboBox", @"slider", @"switch", @"toggleButton",
                                   @"menuItem", @"listBoxOption", @"textFieldWithComboBox"]];
  });
  if ([leaves containsObject:self.chromeRole]) return @[];
  NSMutableArray *a = [NSMutableArray array];
  for (NSNumber *c in self.childIds) {
    ZBAXNode *n = [self.tree node:c.intValue];
    if (n) [a addObject:n];
  }
  return a;
}

- (id)accessibilityParent { return _axParent ?: self.tree.view; }

- (NSRect)accessibilityFrame {
  NSView *view = self.tree.view;
  if (!view.window) return NSZeroRect;
  NSRect inWindow = [view convertRect:self.pageRect toView:nil];
  return [view.window convertRectToScreen:inWindow];
}

- (BOOL)accessibilityPerformPress {
  if (self.tree.press) self.tree.press(self);
  return YES;
}
- (BOOL)isAccessibilityEnabled { return YES; }
- (NSString *)debugDescription {
  NSMutableString *s = [NSMutableString string];
  for (ZBAXNode *n = self; n; n = [n.tree node:n.offsetContainer]) {
    [s appendFormat:@"[%d %@ loc %@ scroll %d,%d container %d] ", n.nodeId, n.chromeRole, NSStringFromRect(n.location), n.scrollX, n.scrollY, n.offsetContainer];
    if (n.offsetContainer == n.nodeId || [n.tree node:n.offsetContainer] == n) break;
  }
  return s;
}
@end
