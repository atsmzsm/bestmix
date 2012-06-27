#import "TasksViewController.h"
#import "Reachability.h"
#import "SVPullToRefresh.h"
#import "Task.h"
#import "UIColor+Hex.h"
#import "MBProgressHUD.h"
#import "TasksApiClient.h"
#import "CoreData+MagicalRecord.h"

const NSInteger kLoadingCellTag = 9999;

@interface TasksViewController ()
{
    UIView *_statusBarOverlay;
}

@end

@implementation TasksViewController

@synthesize reachable = _reachable;
@synthesize currentPage = _currentPage;
@synthesize totalPages = _totalPages;
@synthesize totalCount = _totalCount;

#pragma mark NSObject

- (id)initWithStyle:(UITableViewStyle)style
{
    self = [super initWithStyle:style];
    if (self) {
        // Custom initialization
    }
    return self;
}

#pragma mark UIViewController

- (void)loadView
{
    [super loadView];

    _statusBarOverlay = [[UIView alloc] init];
    _statusBarOverlay.frame = [UIApplication sharedApplication].statusBarFrame;
    _statusBarOverlay.backgroundColor = [UIColor clearColor];
    [[self navigationController].view addSubview:_statusBarOverlay];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.clearsSelectionOnViewWillAppear = NO;

    __block typeof(self) bself = self; // avoid retain cycle

    _reach = [Reachability reachabilityWithHostname:@"www.google.com"];
    _reach.reachableBlock = ^(Reachability *reach) {
        dispatch_async(dispatch_get_main_queue(), ^() {
            bself.reachable = YES;
            _statusBarOverlay.backgroundColor = [UIColor greenColor];
            [bself becomeReachable];
        });
    };
    _reach.unreachableBlock = ^(Reachability *reach) {
        dispatch_async(dispatch_get_main_queue(), ^() {
            bself.reachable = NO;
            _statusBarOverlay.backgroundColor = [UIColor redColor];
            [bself becomeUnreachable];
        });
    };
    [_reach startNotifier];

    [self clearTasks];

    [self.tableView addPullToRefreshWithActionHandler:^{
        bself.currentPage = 1;
        [bself fetch];
    }];
}

- (void)viewDidUnload
{
    [super viewDidUnload];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

#pragma mark UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    id <NSFetchedResultsSectionInfo> sectionInfo = [[_fetchedResultsController sections] objectAtIndex:section];
    NSInteger count = [sectionInfo numberOfObjects];
    NSLog(@"currentPage: %d totalPages: %d count: %d", _currentPage, _totalPages, count);
    if (count == 0)
        return 0;

    if (_currentPage < _totalPages)
        return count + 1;

    return count;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath
{
    // NSLog(@"willDisplayCell - row %d tag: %d", indexPath.row, cell.tag);
    if (cell.tag == kLoadingCellTag) {
        _currentPage += 1;
        [self fetch];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    id <NSFetchedResultsSectionInfo> sectionInfo = [[_fetchedResultsController sections] objectAtIndex:indexPath.section];
    NSInteger count = [sectionInfo numberOfObjects];
    if (indexPath.row == count)
        return [self loadingCell];

    return [self taskCellForIndexPath:indexPath];
}

- (void)becomeReachable
{
    NSLog(@"reachable");
    // _currentPage = 1;
    [self fetch];
}

- (void)becomeUnreachable
{
    NSLog(@"unreachable");
}

- (UITableViewCell *)taskCellForIndexPath:(NSIndexPath *)indexPath
{
    static NSString *TaskCellIdentifier = @"Task";
    UITableViewCell *cell;
    cell = [self.tableView dequeueReusableCellWithIdentifier:TaskCellIdentifier];
    // if (cell == nil) {
    //     cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
    //                                   reuseIdentifier:TaskCellIdentifier];
    // }

    Task *task = [_fetchedResultsController objectAtIndexPath:indexPath];
    // NSLog(@"taskCellForIndexPath - indexPath: %@ task: %@ %@", indexPath, task.name, task.updatedAt);
    cell.textLabel.text = task.name;
    if ([task.pub boolValue])
        cell.textLabel.textColor = [UIColor colorWithHex:0x008000];
    else
        cell.textLabel.textColor = [UIColor colorWithHex:0xff0000];

    NSString *date;
    date = [NSDateFormatter localizedStringFromDate:task.updatedAt
                                          dateStyle:NSDateFormatterShortStyle
                                          timeStyle:NSDateFormatterShortStyle];

    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@", date];
    cell.detailTextLabel.textColor = [UIColor grayColor];

    return cell;
}

- (UITableViewCell *)loadingCell
{
    static NSString *LoadingCellIdentifier = @"Loading";
    UITableViewCell *cell;
    cell = [self.tableView dequeueReusableCellWithIdentifier:LoadingCellIdentifier];
    // if (cell == nil) {
    //     cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
    //                               reuseIdentifier:nil];

    //     UIActivityIndicatorView *indicator;
    //     indicator = [[UIActivityIndicatorView alloc]
    //                  initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    //     indicator.center = cell.center;
    //     [cell addSubview:indicator];

    //     [indicator startAnimating];

    //     cell.tag = kLoadingCellTag;
    // }

    return cell;
}

- (void)fetch
{
    if (_reachable)
        [self fetchFromWebApi];
    else
        [self fetchFromCoreData];
}

- (void)fetchFromWebApiPath:(NSString *)path parameters:(NSDictionary *)params
{
    [self fetchFromWebApiPath:path parameters:params token:nil];
}

- (void)fetchFromWebApiPath:(NSString *)path parameters:(NSDictionary *)params token:(NSString *)token
{
    if (!_reachable) {
        NSLog(@"unable to fetch");
        return;
    }

    if ([self.tableView numberOfRowsInSection:0] == 0) {
        MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
        hud.labelText = @"Loading...";
    }

    TasksApiClient *client = [TasksApiClient sharedClient];
    [client setDefaultHeader:@"Authorization" value:[NSString stringWithFormat:@"Bearer %@", token]];

    [client getPath:path
         parameters:params
            success:^(AFHTTPRequestOperation *operation, id response) {
                NSLog(@"response: %@", response);

                if (_currentPage == 1)
                    [self clearTasks];

                id elem = [response objectForKey:@"num_pages"];
                if (elem && [elem isKindOfClass:[NSNumber class]])
                    _totalPages = [elem integerValue];
                elem = [response objectForKey:@"total_count"];
                if (elem && [elem isKindOfClass:[NSNumber class]])
                    _totalCount = [elem integerValue];
                NSLog(@"currentPage: %d totalPages: %d totalCount: %d", _currentPage, _totalPages, _totalCount);

                elem = [response objectForKey:@"tasks"];
                if (elem && [elem isKindOfClass:[NSArray class]]) {
                    [MagicalRecord saveInBackgroundUsingCurrentContextWithBlock:^(NSManagedObjectContext *context) {
                        [Task MR_importFromArray:elem inContext:context];
                        //NSArray *tasks = [Task MR_importFromArray:elem inContext:context];
                        //NSLog(@"store tasks: %@", tasks);

                    } completion:^{
                        [[NSManagedObjectContext MR_defaultContext] MR_saveNestedContexts]; // why is this required to store data in SQLite?
                        NSLog(@"core data saved");
                        [MBProgressHUD hideHUDForView:self.view animated:YES];
                        [self.tableView.pullToRefreshView stopAnimating];
                        [self fetchFromCoreData];
                        [self.tableView reloadData];

                    } errorHandler:^(NSError *error) {
                        [MBProgressHUD hideHUDForView:self.view animated:YES];
                        [self.tableView.pullToRefreshView stopAnimating];
                        NSLog(@"core data save error: %@ %@", error.localizedDescription, error.userInfo);
                    }];
                }
            }
            failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"error %@", error);
                [MBProgressHUD hideHUDForView:self.view animated:YES];
                [self.tableView.pullToRefreshView stopAnimating];
            }];
}

- (void)fetchFromWebApi
{
    NSLog(@"fetchFromWebApi - currentPage: %d", _currentPage);
}

- (void)fetchFromCoreData
{
    NSLog(@"fetchFromCoreData");
}

- (void)clearTasks
{
    _currentPage = 1;
    _totalPages = 1;
}

@end
