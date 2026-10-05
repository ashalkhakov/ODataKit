// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "DVPeersController.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

typedef NS_ENUM(NSInteger, DVPeersSection) {
  DVPeersThisDevice = 0,
  DVPeersNearby,
  DVPeersPaired,
};

typedef NS_ENUM(NSInteger, DVPeersRow) {
  DVPeersRowToken = 0,
  DVPeersRowServe,
  DVPeersRowOffer,
  DVPeersRowPair,
};

static NSString *DVShortDate(NSDate *date)
{
  return [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
}

static void DVPeersAlert(UIViewController *controller, NSString *title, NSString *message)
{
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Peers

@implementation DVPeersController

- (instancetype)initWithSession:(DVSession *)session style:(UITableViewStyle)style
{
  self = [super initWithSession:session style:style];
  if (!self) return nil;
  self.title = @"Peers";
  self.tabBarItem.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(peersChanged:) name:DVPeersDidChangeNotification object:nil];
  return self;
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  // Looking only once the tab is seen: iOS asks for the local network then.
  [self.session.peers startBrowsing];
}

- (void)peersChanged:(NSNotification *)notification
{
  if (notification.object != self.session.peers || !self.isViewLoaded) return;
  [self reload];
}

- (DVPeers *)peers
{
  return self.session.peers;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
  return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  DVPeers *peers = [self peers];
  if (!peers) return 0;
  switch ((DVPeersSection)section) {
    case DVPeersThisDevice: return 4;
    case DVPeersNearby: return (NSInteger)peers.found.count;
    case DVPeersPaired: return (NSInteger)peers.pairings.count;
  }
  return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
  return @[ @"This device", @"Nearby", @"Paired" ][(NSUInteger)section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
  DVPeers *peers = [self peers];
  switch ((DVPeersSection)section) {
    case DVPeersThisDevice:
      if (!peers) return self.session.device ? self.session.status : @"Set the Workbench's address in Settings first.";
      return @"Devices sync with each other when each has a peer token from the Workbench (the same one), or once paired: one shows its "
             @"Pairing Code, the other scans it. Either way the connection is TLS, each device's certificate checked.";
    case DVPeersNearby:
      return peers.found.count ? @"Tap a device to sync with it: its changes come down, this device's go up."
                               : @"No device nearby serves to peers: on another device, Serve to Peers (the same network).";
    case DVPeersPaired:
      return peers.pairings.count ? @"Swipe to forget a device: it then needs a token, or to pair again." : nil;
  }
  return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  DVPeers *peers = [self peers];
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
  content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
  switch ((DVPeersSection)indexPath.section) {
    case DVPeersThisDevice:
      switch ((DVPeersRow)indexPath.row) {
        case DVPeersRowToken:
          content.text = peers.fetchingToken ? @"Getting a Peer Token…" : @"Get a Peer Token";
          content.secondaryText = peers.hasToken ? [@"One, until " stringByAppendingString:DVShortDate(peers.tokenExpires ?: [NSDate distantFuture])]
                                                 : @"None: from the Workbench";
          content.textProperties.color = peers.fetchingToken ? UIColor.secondaryLabelColor : self.view.tintColor;
          break;
        case DVPeersRowServe: {
          UISwitch *toggle = [[UISwitch alloc] init];
          toggle.on = peers.serving;
          [toggle addTarget:self action:@selector(serveChanged:) forControlEvents:UIControlEventValueChanged];
          content.text = @"Serve to Peers";
          content.secondaryText = peers.serviceRoot.absoluteString ?: [NSString stringWithFormat:@"Port %lu, advertised nearby", (unsigned long)DVPeersPort];
          cell.accessoryView = toggle;
          cell.selectionStyle = UITableViewCellSelectionStyleNone;
          break;
        }
        case DVPeersRowOffer:
          content.text = @"Show Pairing Code";
          content.secondaryText = peers.serving ? @"For the other device to scan" : @"While serving to peers";
          content.textProperties.color = peers.serving ? self.view.tintColor : UIColor.secondaryLabelColor;
          break;
        case DVPeersRowPair:
          content.text = @"Pair with a Device…";
          content.secondaryText = @"Scan (or paste) its pairing code";
          content.textProperties.color = self.view.tintColor;
          break;
      }
      break;
    case DVPeersNearby: {
      ODataSyncPeerAnnouncement *peer = peers.found[(NSUInteger)indexPath.row];
      content.text = peer.name;
      content.secondaryText = [NSString stringWithFormat:@"%@%@", [peers pairingOfPeer:peer] ? @"Paired · " : @"", peer.serviceRoot.host];
      content.image = [UIImage systemImageNamed:@"iphone"];
      break;
    }
    case DVPeersPaired: {
      ODataSyncPeerPairing *pairing = peers.pairings[(NSUInteger)indexPath.row];
      content.text = pairing.name ?: pairing.replica;
      content.secondaryText = [@"Paired " stringByAppendingString:DVShortDate(pairing.date)];
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      break;
    }
  }
  cell.contentConfiguration = content;
  return cell;
}

- (void)serveChanged:(UISwitch *)toggle
{
  DVPeers *peers = [self peers];
  if (!toggle.on) {
    [peers stopServing];
    return;
  }
  NSError *error = nil;
  if (![peers startServing:&error]) {
    toggle.on = NO;
    DVPeersAlert(self, @"Not serving to peers", error.localizedDescription);
  }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  DVPeers *peers = [self peers];
  if (indexPath.section == DVPeersNearby) {
    [peers syncWithPeer:peers.found[(NSUInteger)indexPath.row]];
    return;
  }
  if (indexPath.section != DVPeersThisDevice) return;
  switch ((DVPeersRow)indexPath.row) {
    case DVPeersRowToken:
      [peers fetchToken];
      break;
    case DVPeersRowServe:
      break;
    case DVPeersRowOffer:
      if (!peers.serving) {
        DVPeersAlert(self, @"Not serving", @"Turn on Serve to Peers first: the other device pairs at this device's address.");
        return;
      }
      [self.navigationController pushViewController:[[DVOfferController alloc] initWithPeers:peers] animated:YES];
      break;
    case DVPeersRowPair: {
      __weak DVPeersController *weak = self;
      DVScanController *scan = [[DVScanController alloc] initWithOffer:^(NSString *text) {
        [weak pairWithOffer:text];
      }];
      [self.navigationController pushViewController:scan animated:YES];
      break;
    }
  }
}

- (void)pairWithOffer:(NSString *)text
{
  [self.navigationController popToViewController:self animated:YES];
  __weak DVPeersController *weak = self;
  [[self peers] pairWithOffer:text completion:^(NSError *error) {
    DVPeersController *strong = weak;
    if (error && strong) DVPeersAlert(strong, @"Not paired", error.localizedDescription);
  }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
  if (indexPath.section != DVPeersPaired) return nil;
  DVPeers *peers = [self peers];
  ODataSyncPeerPairing *pairing = peers.pairings[(NSUInteger)indexPath.row];
  __weak DVPeersController *weak = self;
  UIContextualAction *forget = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Forget"
                                                                     handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
    NSError *error = nil;
    BOOL ok = [peers forgetPairing:pairing error:&error];
    if (!ok && weak) DVPeersAlert(weak, @"Not forgotten", error.localizedDescription);
    done(ok);
  }];
  return [UISwipeActionsConfiguration configurationWithActions:@[ forget ]];
}

@end

#pragma mark - The offer

@implementation DVOfferController {
  DVPeers *_peers;
  UIImageView *_codeView;
  UILabel *_textLabel;
  UILabel *_expiresLabel;
  NSString *_offer;
  NSDate *_expires;
  NSTimer *_timer;
}

- (instancetype)initWithPeers:(DVPeers *)peers
{
  self = [super initWithNibName:nil bundle:nil];
  if (!self) return nil;
  _peers = peers;
  self.title = @"Pairing Code";
  return self;
}

- (void)loadView
{
  UIView *view = [[UIView alloc] init];
  view.backgroundColor = UIColor.systemBackgroundColor;
  _codeView = [[UIImageView alloc] init];
  _codeView.contentMode = UIViewContentModeScaleAspectFit;
  _codeView.layer.magnificationFilter = kCAFilterNearest;
  _codeView.backgroundColor = UIColor.whiteColor;
  _expiresLabel = [[UILabel alloc] init];
  _expiresLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
  _expiresLabel.textAlignment = NSTextAlignmentCenter;
  _textLabel = [[UILabel alloc] init];
  _textLabel.numberOfLines = 0;
  _textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
  _textLabel.textColor = UIColor.secondaryLabelColor;
  UILabel *hint = [[UILabel alloc] init];
  hint.numberOfLines = 0;
  hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  hint.textColor = UIColor.secondaryLabelColor;
  hint.text = @"On the other device: Peers, Pair with a Device, and scan this; or copy the text below and paste it there. Good once, for "
              @"two minutes.";
  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ _codeView, _expiresLabel, hint, _textLabel ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 12;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  UIScrollView *scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:stack];
  [view addSubview:scroll];
  UILayoutGuide *margins = view.layoutMarginsGuide;
  [NSLayoutConstraint activateConstraints:@[
    [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
    [scroll.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
    [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
    [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
    [_codeView.heightAnchor constraintEqualToAnchor:_codeView.widthAnchor],
    [_codeView.widthAnchor constraintLessThanOrEqualToConstant:360] ]];
  self.view = view;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  self.navigationItem.rightBarButtonItems = @[
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(renew:)],
    [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"] style:UIBarButtonItemStylePlain target:self action:@selector(copyOffer:)] ];
  [self renew:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  __weak DVOfferController *weak = self;
  _timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
    [weak tick];
  }];
}

- (void)viewWillDisappear:(BOOL)animated
{
  [super viewWillDisappear:animated];
  [_timer invalidate];
  _timer = nil;
}

// A QR code of the text, a module a pixel (the view scales it up, sharp).
static UIImage *DVQRCode(NSString *text)
{
  CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
  [filter setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
  [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
  CIImage *image = [filter.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(8, 8)];
  if (!image) return nil;
  CGImageRef cgImage = [[CIContext contextWithOptions:nil] createCGImage:image fromRect:image.extent];
  UIImage *code = cgImage ? [UIImage imageWithCGImage:cgImage] : nil;
  if (cgImage) CGImageRelease(cgImage);
  return code;
}

- (void)renew:(id)sender
{
  _offer = [_peers newPairingOffer];
  _expires = _offer ? [NSDate dateWithTimeIntervalSinceNow:120] : nil;
  _codeView.image = _offer ? DVQRCode(_offer) : nil;
  _textLabel.text = _offer ?: @"Not serving to peers: no offer.";
  [self tick];
}

- (void)tick
{
  NSTimeInterval left = _expires.timeIntervalSinceNow;
  if (!_offer) {
    _expiresLabel.text = @"No offer";
  } else if (left <= 0) {
    _expiresLabel.text = @"Expired: renew it";
    _codeView.alpha = 0.2;
  } else {
    _expiresLabel.text = [NSString stringWithFormat:@"Good for %d:%02d", (int)left / 60, (int)left % 60];
    _codeView.alpha = 1;
  }
}

- (void)copyOffer:(id)sender
{
  if (_offer) UIPasteboard.generalPasteboard.string = _offer;
}

@end

#pragma mark - Scanning

@interface DVScanController () <AVCaptureMetadataOutputObjectsDelegate>
@end

@implementation DVScanController {
  void (^_offer)(NSString *);
  AVCaptureSession *_capture;
  AVCaptureVideoPreviewLayer *_preview;
  UILabel *_label;
  BOOL _read;
}

- (instancetype)initWithOffer:(void (^)(NSString *))offer
{
  self = [super initWithNibName:nil bundle:nil];
  if (!self) return nil;
  _offer = [offer copy];
  self.title = @"Pair";
  return self;
}

- (void)loadView
{
  UIView *view = [[UIView alloc] init];
  view.backgroundColor = UIColor.blackColor;
  _label = [[UILabel alloc] init];
  _label.numberOfLines = 0;
  _label.textAlignment = NSTextAlignmentCenter;
  _label.textColor = UIColor.whiteColor;
  _label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  _label.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:_label];
  UILayoutGuide *margins = view.layoutMarginsGuide;
  [NSLayoutConstraint activateConstraints:@[
    [_label.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
    [_label.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
    [_label.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-24] ]];
  self.view = view;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Paste" style:UIBarButtonItemStylePlain target:self action:@selector(paste:)];
  AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  if (!camera) {
    _label.text = @"No camera here: on the other device, copy its pairing code's text, then Paste.";
    return;
  }
  _label.text = @"Point the camera at the other device's pairing code (Peers, Show Pairing Code).";
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (granted) [self startCamera:camera];
      else self->_label.text = @"No access to the camera (Settings, Privacy): Paste the code's text instead.";
    });
  }];
}

- (void)startCamera:(AVCaptureDevice *)camera
{
  NSError *error = nil;
  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:camera error:&error];
  AVCaptureSession *capture = [[AVCaptureSession alloc] init];
  AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
  if (!input || ![capture canAddInput:input] || ![capture canAddOutput:output]) {
    _label.text = [NSString stringWithFormat:@"The camera does not start (%@): Paste the code's text instead.", error.localizedDescription ?: @"in use"];
    return;
  }
  [capture addInput:input];
  [capture addOutput:output];
  [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
  output.metadataObjectTypes = @[ AVMetadataObjectTypeQRCode ];
  _preview = [AVCaptureVideoPreviewLayer layerWithSession:capture];
  _preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
  _preview.frame = self.view.bounds;
  [self.view.layer insertSublayer:_preview atIndex:0];
  _capture = capture;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [capture startRunning];
  });
}

- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  _preview.frame = self.view.bounds;
}

- (void)viewWillDisappear:(BOOL)animated
{
  [super viewWillDisappear:animated];
  AVCaptureSession *capture = _capture;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [capture stopRunning];
  });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)objects
       fromConnection:(AVCaptureConnection *)connection
{
  for (AVMetadataObject *object in objects) {
    if (![object isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) continue;
    NSString *text = [(AVMetadataMachineReadableCodeObject *)object stringValue];
    if (!text.length || _read) continue;
    _read = YES;
    _offer(text);
    return;
  }
}

- (void)paste:(id)sender
{
  NSString *text = UIPasteboard.generalPasteboard.string;
  if (!text.length) {
    DVPeersAlert(self, @"Nothing to paste", @"Copy the pairing code's text on the other device first.");
    return;
  }
  _read = YES;
  _offer(text);
}

@end
