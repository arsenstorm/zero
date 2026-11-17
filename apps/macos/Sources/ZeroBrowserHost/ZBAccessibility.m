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
static NSString *Str(id v) { return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }
static BOOL Has(id list, NSString *state) { return [list isKindOfClass:NSArray.class] && [list containsObject:state]; }

// Landmarks, as Safari and Chromium's own Mac tree give them: a group with the landmark's subrole and name.
static NSDictionary<NSString *, NSArray<NSString *> *> *Landmarks(void) {
  static NSDictionary *map;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = @{
      @"main": @[@"AXLandmarkMain", @"main"], @"navigation": @[@"AXLandmarkNavigation", @"navigation"],
      @"banner": @[@"AXLandmarkBanner", @"banner"], @"contentInfo": @[@"AXLandmarkContentInfo", @"content information"],
      @"complementary": @[@"AXLandmarkComplementary", @"complementary"], @"search": @[@"AXLandmarkSearch", @"search"],
      @"region": @[@"AXLandmarkRegion", @"region"],
    };
  });
  return map;
}

@interface ZBAXTree ()
- (nullable ZBAXNode *)node:(int)nodeId in:(NSString *)doc;
- (nullable ZBAXNode *)rootOf:(nullable NSString *)doc;
- (nullable ZBAXNode *)hostOf:(nullable NSString *)doc;
@end

@interface ZBAXNode ()
@property (nonatomic, weak) ZBAXTree *tree;
@property (nonatomic, copy) NSString *doc;  // the document's tree: the page's, or an iframe's
@property (nonatomic) int nodeId, offsetContainer, scrollX, scrollY;
@property (nonatomic, copy) NSString *chromeRole, *name, *valueText, *details;
@property (nonatomic) CGRect location;
@property (nonatomic, copy) NSArray<NSNumber *> *childIds;
@property (nonatomic, copy) NSDictionary *attributes;
@property (nonatomic, copy) id states;  // Chromium's states: a list ("protected", "focusable"…)
- (id)accessibilityValue;
- (BOOL)isExpandable;
@end

/// One document's nodes: the page's, or an iframe's (its own tree in Chromium, with its own node ids).
@interface ZBAXDoc : NSObject
@property (nonatomic, readonly) NSMutableDictionary<NSNumber *, ZBAXNode *> *nodes;
@property (nonatomic) int root, focus;
@property (nonatomic, weak) ZBAXNode *host;  // the iframe it is in
@property (nonatomic, copy) NSString *parent;  // its parent document's tree
@end
@implementation ZBAXDoc
- (instancetype)init {
  if ((self = [super init])) {
    _nodes = [NSMutableDictionary dictionary];
    _root = -1;
    _focus = -1;
  }
  return self;
}
@end

@implementation ZBAXTree {
  // ponytail: an iframe's document stays until the page navigates, even once the iframe has gone or navigated.
  NSMutableDictionary<NSString *, ZBAXDoc *> *_docs;
  NSString *_focusedDoc;
}

- (instancetype)init {
  if ((self = [super init])) _docs = [NSMutableDictionary dictionary];
  return self;
}

- (ZBAXDoc *)page { return _treeId ? _docs[_treeId] : nil; }
- (ZBAXNode *)root { return self.page.nodes[@(self.page.root)]; }
- (ZBAXNode *)focused {
  ZBAXDoc *doc = _docs[_focusedDoc ?: _treeId ?: @""] ?: self.page;
  return doc.nodes[@(doc.focus)];
}
- (ZBAXNode *)node:(int)nodeId { return self.page.nodes[@(nodeId)]; }
- (ZBAXNode *)node:(int)nodeId in:(NSString *)doc { return _docs[doc].nodes[@(nodeId)]; }
- (ZBAXNode *)rootOf:(NSString *)doc { return doc ? _docs[doc].nodes[@(_docs[doc].root)] : nil; }
- (ZBAXNode *)hostOf:(NSString *)doc { return doc ? _docs[doc].host : nil; }
- (NSUInteger)count {
  NSUInteger n = 0;
  for (ZBAXDoc *d in _docs.allValues) n += d.nodes.count;
  return n;
}

- (void)remove:(int)nodeId in:(ZBAXDoc *)doc gone:(NSMutableDictionary *)gone {
  ZBAXNode *n = doc.nodes[@(nodeId)];
  if (!n) return;
  gone[@(nodeId)] = n;
  for (NSNumber *c in n.childIds) [self remove:c.intValue in:doc gone:gone];
  [doc.nodes removeObjectForKey:@(nodeId)];
}

// Only for a page in view: a hidden task's tab says nothing.
- (void)post:(id)element name:(NSString *)name info:(NSDictionary *)info {
  if (!element || !self.view.window || self.view.isHiddenOrHasHiddenAncestor) return;
  if (self.posted) self.posted(element, name, info);
  if (info)
    NSAccessibilityPostNotificationWithUserInfo(element, name, info);
  else
    NSAccessibilityPostNotification(element, name);
}

/// One OnAccessibilityTreeChange: {ax_tree_id, events, updates: [{node_id_to_clear, tree_data, root_id, nodes: [...]}]},
/// for the page's document or an iframe's (its tree data names its parent's tree).
- (void)apply:(NSString *)json {
  NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![d isKindOfClass:NSDictionary.class]) return;
  NSString *tree = Str(d[@"ax_tree_id"]);
  if (!tree) return;
  NSDictionary *data = nil;
  for (NSDictionary *u in d[@"updates"])
    if ([u[@"tree_data"] isKindOfClass:NSDictionary.class]) { data = u[@"tree_data"]; break; }
  ZBAXDoc *doc = _docs[tree];
  if (!doc) {
    // A document with no parent tree is the page's: a new one means the tab navigated.
    if (!Str(data[@"parent_tree_id"])) {
      if (_treeId && !data) return;
      // An iframe's document can come before its page's.
      for (NSString *key in _docs.allKeys)
        if (![_docs[key].parent isEqual:tree]) [_docs removeObjectForKey:key];
      _treeId = tree;
      _url = nil;
      _focusedDoc = nil;
    }
    doc = _docs[tree] = [ZBAXDoc new];
  }
  if (Str(data[@"parent_tree_id"])) doc.parent = data[@"parent_tree_id"];
  // Changes VoiceOver hears as they happen, once the document is there: live regions' new text, values, states.
  BOOL settled = doc.root >= 0, loaded = NO;
  for (NSDictionary *e in d[@"events"]) {
    if ([e[@"event_type"] isEqual:@"loadStart"] || [e[@"event_type"] isEqual:@"loadComplete"]) settled = NO;
    if ([e[@"event_type"] isEqual:@"loadComplete"]) loaded = YES;
  }
  // Nodes Chromium clears and sends again are the same nodes: compared with what they were, not taken as new.
  NSMutableDictionary<NSNumber *, ZBAXNode *> *gone = [NSMutableDictionary dictionary];
  NSMutableArray *polite = [NSMutableArray array], *assertive = [NSMutableArray array], *changes = [NSMutableArray array];
  for (NSDictionary *u in d[@"updates"]) {
    if (u[@"node_id_to_clear"]) [self remove:Int(u[@"node_id_to_clear"]) in:doc gone:gone];
    if ([u[@"has_tree_data"] boolValue] || u[@"tree_data"]) {
      NSDictionary *data = u[@"tree_data"];
      if (data[@"focus_id"]) doc.focus = Int(data[@"focus_id"]);
      if ([tree isEqual:_treeId]) {
        if (Str(data[@"url"])) _url = [data[@"url"] copy];
        if (data[@"focused_tree_id"]) _focusedDoc = Str(data[@"focused_tree_id"]);
      }
    }
    if (u[@"root_id"]) doc.root = Int(u[@"root_id"]);
    for (NSDictionary *n in u[@"nodes"]) {
      int nid = Int(n[@"id"]);
      ZBAXNode *node = doc.nodes[@(nid)], *before = node ?: gone[@(nid)];
      BOOL known = before != nil;
      id value = before.accessibilityValue;
      NSString *name = before.name;
      BOOL expanded = Has(before.states, @"expanded");
      if (!node) {
        node = [ZBAXNode new];
        node.tree = self;
        node.doc = tree;
        node.nodeId = nid;
        doc.nodes[@(nid)] = node;
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
      if ([node.chromeRole isEqual:@"rootWebArea"] && doc.root < 0) doc.root = nid;
      if (!settled) continue;
      NSString *live = node.attributes[@"containerLiveStatus"];
      if ([node.chromeRole isEqual:@"staticText"] && node.name.length && !(known && [name isEqual:node.name])) {
        if ([live isEqual:@"assertive"]) [assertive addObject:node.name];
        else if ([live isEqual:@"polite"]) [polite addObject:node.name];
      }
      if (!known) continue;
      id now = node.accessibilityValue;
      if (value != now && ![value isEqual:now]) [changes addObject:@[node, NSAccessibilityValueChangedNotification]];
      if (expanded != Has(node.states, @"expanded") && node.isExpandable) [changes addObject:@[node, @"AXExpandedChanged"]];
      if (name != node.name && ![name isEqual:node.name] && ![node.chromeRole isEqual:@"staticText"])
        [changes addObject:@[node, NSAccessibilityTitleChangedNotification]];
    }
  }
  // Parents follow children lists; an iframe's document hangs from the iframe.
  for (ZBAXNode *n in doc.nodes.allValues) {
    for (NSNumber *c in n.childIds) [doc.nodes[c] setValue:n forKey:@"axParent"];
    NSString *child = Str(n.attributes[@"childTreeId"]);
    if (child) {
      ZBAXDoc *inner = _docs[child] ?: (_docs[child] = [ZBAXDoc new]);
      inner.host = n;
    }
  }
  if (loaded && [tree isEqual:_treeId]) [self post:[self rootOf:tree] name:@"AXLoadComplete" info:nil];
  for (NSArray *c in changes) [self post:c[0] name:c[1] info:nil];
  // Spoken over what VoiceOver is reading for assertive regions, after it for polite ones.
  for (NSArray *said in @[@[assertive, @(NSAccessibilityPriorityHigh)], @[polite, @(NSAccessibilityPriorityMedium)]])
    if ([said[0] count])
      [self post:self.view.window ?: NSApp name:NSAccessibilityAnnouncementRequestedNotification
            info:@{NSAccessibilityAnnouncementKey: [said[0] componentsJoinedByString:@" "], NSAccessibilityPriorityKey: said[1]}];
}

/// OnAccessibilityLocationChange: [{ax_tree_id, id, new_location: {bounds: {...}, offset_container_id}}].
- (void)move:(NSString *)json {
  NSArray *list = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![list isKindOfClass:NSArray.class]) return;
  for (NSDictionary *c in list) {
    ZBAXNode *n = [self node:Int(c[@"id"]) in:Str(c[@"ax_tree_id"]) ?: @""];
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

/// Its location in its offset container's, less its own scroll, in device pixels. An iframe's document is placed in
/// the iframe.
- (CGRect)pixelRect {
  CGRect r = self.location;
  r.origin.x -= self.scrollX;
  r.origin.y -= self.scrollY;
  ZBAXNode *container = [self.tree node:self.offsetContainer in:self.doc];
  if ((!container || container == self) && [self.tree rootOf:self.doc] == self) container = [self.tree hostOf:self.doc];
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
  return Landmarks()[self.chromeRole][1] ?: NSAccessibilityRoleDescription(self.accessibilityRole, self.accessibilitySubrole);
}
- (NSString *)accessibilityLabel { return self.name; }
- (NSString *)accessibilityTitle { return self.name; }
// A heading's value is its level; a check box's 0, 1 or 2 (mixed); a tab's whether it is selected.
- (id)accessibilityValue {
  NSString *role = self.chromeRole;
  if ([role isEqual:@"heading"]) return self.attributes[@"hierarchicalLevel"] ? @(Int(self.attributes[@"hierarchicalLevel"])) : nil;
  if ([@[@"checkBox", @"switch", @"toggleButton", @"radioButton", @"menuItemCheckBox", @"menuItemRadio"] containsObject:role ?: @""]) {
    NSString *checked = self.attributes[@"checkedState"];
    return @([checked isEqual:@"mixed"] ? 2 : [checked isEqual:@"true"] ? 1 : 0);
  }
  if ([role isEqual:@"tab"]) return @([self.attributes[@"selected"] boolValue]);
  return self.valueText;
}
- (NSString *)accessibilityHelp { return self.details; }
- (BOOL)isAccessibilitySelected { return [self.attributes[@"selected"] boolValue]; }
- (BOOL)isExpandable { return Has(self.states, @"expanded") || Has(self.states, @"collapsed"); }
- (BOOL)isRequired { return Has(self.states, @"required"); }
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
- (NSAccessibilitySubrole)accessibilitySubrole {
  return self.isSecure ? NSAccessibilitySecureTextFieldSubrole : Landmarks()[self.chromeRole][0];
}
// A placeholder that names the field (no label) is in its name only, as Chromium's own Mac tree reads it.
- (NSString *)accessibilityPlaceholderValue {
  return self.attributes[@"placeholder"] ?: ([self.attributes[@"nameFrom"] isEqual:@"placeholder"] ? self.name : nil);
}
- (NSArray *)accessibilityChildrenInNavigationOrder { return self.accessibilityChildren; }
- (NSArray<NSAccessibilityAttributeName> *)accessibilityAttributeNames {
  NSMutableArray *names = [[super accessibilityAttributeNames] mutableCopy] ?: [NSMutableArray array];
  NSMutableArray *more = [@[@"AXDOMIdentifier", @"AXDOMClassList", NSAccessibilityURLAttribute, NSAccessibilityPlaceholderValueAttribute] mutableCopy];
  if (self.isExpandable) [more addObject:NSAccessibilityExpandedAttribute];
  if (self.isRequired) [more addObject:@"AXRequired"];
  for (NSString *name in more)
    if (![names containsObject:name]) [names addObject:name];
  return names;
}
- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)name {
  if ([name isEqual:NSAccessibilityExpandedAttribute]) return self.isExpandable ? @(Has(self.states, @"expanded")) : nil;
  if ([name isEqual:@"AXRequired"]) return @(self.isRequired);
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

// VoiceOver's rotor and its quick keys (next heading, link, form control…): Safari's search predicate, answered from
// the element's subtree in document order, iframes' documents included.
static NSString *const kSearch = @"AXUIElementsForSearchPredicate", *const kCount = @"AXUIElementCountForSearchPredicate";

- (NSArray *)accessibilityParameterizedAttributeNames {
  NSArray *names = [NSAccessibilityElement instancesRespondToSelector:_cmd] ? [super accessibilityParameterizedAttributeNames] : nil;
  return [names ?: @[] arrayByAddingObjectsFromArray:@[kSearch, kCount]];
}
- (id)accessibilityAttributeValue:(NSAccessibilityParameterizedAttributeName)name forParameter:(id)parameter {
  if ([name isEqual:kSearch] || [name isEqual:kCount]) {
    NSArray *found = [self search:[parameter isKindOfClass:NSDictionary.class] ? parameter : @{}];
    return [name isEqual:kCount] ? @(found.count) : found;
  }
  return [NSAccessibilityElement instancesRespondToSelector:_cmd] ? [super accessibilityAttributeValue:name forParameter:parameter] : nil;
}

- (void)collect:(NSMutableArray *)into deep:(BOOL)deep {
  for (ZBAXNode *c in self.accessibilityChildren) {
    [into addObject:c];
    if (deep) [c collect:into deep:YES];
  }
}

static BOOL Matches(ZBAXNode *n, NSString *key, ZBAXNode *start) {
  static NSDictionary<NSString *, NSSet *> *roles;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSArray *buttons = @[@"button", @"toggleButton", @"menuButton", @"popUpButton", @"buttonDropDown"];
    NSArray *fields = @[@"textField", @"searchBox", @"textFieldWithComboBox", @"comboBox"];
    NSArray *controls = [[buttons arrayByAddingObjectsFromArray:fields] arrayByAddingObjectsFromArray:@[
      @"checkBox", @"switch", @"radioButton", @"slider", @"spinButton", @"listBox", @"colorWell", @"date", @"dateTime",
      @"inputTime"]];
    roles = @{
      @"AXHeadingSearchKey": [NSSet setWithObject:@"heading"],
      @"AXLinkSearchKey": [NSSet setWithObjects:@"link", @"imageMapLink", nil],
      @"AXButtonSearchKey": [NSSet setWithArray:buttons],
      @"AXTextFieldSearchKey": [NSSet setWithArray:fields],
      @"AXControlSearchKey": [NSSet setWithArray:controls],
      @"AXCheckBoxSearchKey": [NSSet setWithObjects:@"checkBox", @"switch", nil],
      @"AXRadioGroupSearchKey": [NSSet setWithObject:@"radioGroup"],
      @"AXLandmarkSearchKey": [NSSet setWithArray:Landmarks().allKeys],
      @"AXTableSearchKey": [NSSet setWithObjects:@"table", @"grid", @"treeGrid", nil],
      @"AXListSearchKey": [NSSet setWithObjects:@"list", @"descriptionList", nil],
      @"AXGraphicSearchKey": [NSSet setWithObjects:@"image", @"canvas", @"svgRoot", nil],
      @"AXStaticTextSearchKey": [NSSet setWithObject:@"staticText"],
      @"AXArticleSearchKey": [NSSet setWithObject:@"article"],
      @"AXBlockquoteSearchKey": [NSSet setWithObject:@"blockquote"],
      @"AXFrameSearchKey": [NSSet setWithObject:@"rootWebArea"],
    };
  });
  NSString *role = n.chromeRole ?: @"";
  if ([key isEqual:@"AXAnyTypeSearchKey"]) return YES;
  if ([key isEqual:@"AXSameTypeSearchKey"]) return start && [role isEqual:start.chromeRole];
  if ([key hasPrefix:@"AXHeadingLevel"] && [key hasSuffix:@"SearchKey"])
    return [role isEqual:@"heading"] && Int(n.attributes[@"hierarchicalLevel"]) == [key substringFromIndex:14].intValue;
  if ([key isEqual:@"AXVisitedLinkSearchKey"] || [key isEqual:@"AXUnvisitedLinkSearchKey"])
    return [role isEqual:@"link"] && Has(n.states, @"visited") == [key isEqual:@"AXVisitedLinkSearchKey"];
  return [roles[key] containsObject:role];
}

/// The search: {AXSearchKey (one or a list), AXStartElement, AXDirection, AXResultsLimit, AXSearchText,
/// AXImmediateDescendantsOnly}.
- (NSArray *)search:(NSDictionary *)p {
  NSMutableArray *all = [NSMutableArray array];
  [self collect:all deep:![p[@"AXImmediateDescendantsOnly"] boolValue]];
  ZBAXNode *start = [p[@"AXStartElement"] isKindOfClass:ZBAXNode.class] ? p[@"AXStartElement"] : nil;
  BOOL back = [p[@"AXDirection"] isEqual:@"AXDirectionPrevious"];
  NSUInteger at = start ? [all indexOfObjectIdenticalTo:start] : NSNotFound;
  NSArray *order = at == NSNotFound ? all : back ? [all subarrayWithRange:NSMakeRange(0, at)] : [all subarrayWithRange:NSMakeRange(at + 1, all.count - at - 1)];
  if (back) order = order.reverseObjectEnumerator.allObjects;
  id keys = p[@"AXSearchKey"] ?: @"AXAnyTypeSearchKey";
  if (![keys isKindOfClass:NSArray.class]) keys = @[keys];
  NSString *text = Str(p[@"AXSearchText"]);
  NSInteger limit = [p[@"AXResultsLimit"] integerValue];
  NSMutableArray *found = [NSMutableArray array];
  for (ZBAXNode *n in order) {
    if (!n.isAccessibilityElement || Has(n.states, @"ignored")) continue;
    BOOL match = NO;
    for (NSString *key in keys) match = match || ([key isKindOfClass:NSString.class] && Matches(n, key, start));
    if (!match || (text && ![n.name localizedCaseInsensitiveContainsString:text])) continue;
    [found addObject:n];
    if (limit > 0 && (NSInteger)found.count >= limit) break;
  }
  return found;
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
  // An iframe's child is its document's web area.
  NSString *inner = Str(self.attributes[@"childTreeId"]);
  if (inner) {
    ZBAXNode *root = [self.tree rootOf:inner];
    return root ? @[root] : @[];
  }
  NSMutableArray *a = [NSMutableArray array];
  for (NSNumber *c in self.childIds) {
    ZBAXNode *n = [self.tree node:c.intValue in:self.doc];
    if (n) [a addObject:n];
  }
  return a;
}

// An iframe's document's web area is the iframe's child.
- (id)accessibilityParent {
  if (_axParent) return _axParent;
  ZBAXNode *host = [self.tree rootOf:self.doc] == self ? [self.tree hostOf:self.doc] : nil;
  return host ?: self.tree.view;
}

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
- (BOOL)isAccessibilityEnabled { return ![self.attributes[@"restriction"] isEqual:@"disabled"]; }
- (NSString *)debugDescription {
  NSMutableString *s = [NSMutableString string];
  for (ZBAXNode *n = self; n; n = [n.tree node:n.offsetContainer in:n.doc]) {
    [s appendFormat:@"[%d %@ loc %@ scroll %d,%d container %d] ", n.nodeId, n.chromeRole, NSStringFromRect(n.location), n.scrollX, n.scrollY, n.offsetContainer];
    if (n.offsetContainer == n.nodeId || [n.tree node:n.offsetContainer in:n.doc] == n) break;
  }
  return s;
}
@end
