//
//  FSCHarmonyClient.m
//  HarmonyX
//
//  Created by Philippe Boudreau on 2014-11-06.
//  Copyright (c) 2014 Fasterre. All rights reserved.
//

#import "FSCHarmonyClient.h"

#import <AFNetworking/AFNetworking.h>
#import <XMPPFramework/XMPP.h>

#import "FSCHarmonyCommon.h"

static NSString * const MY_HARMONY_AUTH_URL = @"https://svcs.myharmony.com/CompositeSecurityServices/Security.svc/json/GetUserAuthToken";

static NSString * const GENERAL_HARMONY_HUB_USERNAME = @"guest@connect.logitech.com/harmonyx";
static NSString * const GENERAL_HARMONY_HUB_PASSWORD = @"harmonyx";

@interface FSCHarmonyClient ()
{
    BOOL didDisconnectWhileConnecting;
    BOOL isXMPPConnected;
    BOOL isXMPPAuthenticated;
    BOOL didXMPPFailAuthentication;
    BOOL validOAResponseReceived;
}

@property (nonatomic, strong) FSCActivity * currentActivity;

@property (nonatomic, strong) NSDate * creationTime;
@property (nonatomic, strong) NSTimer * heartbeatTimer;

@property (nonatomic, copy) NSString * myHarmonyUsername;
@property (nonatomic, copy) NSString * myHarmonyPassword;
@property (nonatomic, copy) NSString * harmonyHubIPAddress;
@property (nonatomic, assign) NSUInteger harmonyHubPort;

@property (nonatomic, strong) XMPPStream * xmppStream;

@property (nonatomic, strong) NSXMLElement * authenticationFailureError;

@property (nonatomic, copy) BOOL(^OAResponseValidationBlock)(NSXMLElement * OAResponse);
@property (nonatomic, copy) NSString * expectedOAResponseMime;
@property (nonatomic, strong) id validOAResponse;

@end

@implementation FSCHarmonyClient

#pragma mark - Class Methods

- (id) initWithMyHarmonyUsername: (NSString *) username
               myHarmonyPassword: (NSString *) password
             harmonyHubIPAddress: (NSString *) IPAddress
                  harmonyHubPort: (NSUInteger) port
{
    NSLog(@"Creating client");
    
    if (self = [super init])
    {
        [self setCreationTime: [NSDate date]];
        
        [self setMyHarmonyUsername: username];
        [self setMyHarmonyPassword: password];
        [self setHarmonyHubIPAddress: IPAddress];
        [self setHarmonyHubPort: port];
        
        didDisconnectWhileConnecting = NO;
        isXMPPConnected = NO;
        isXMPPAuthenticated = NO;
        didXMPPFailAuthentication = NO;
        validOAResponseReceived = NO;
    }
    
    return self;
}

+ (id) clientWithMyHarmonyUsername: (NSString *) username
                 myHarmonyPassword: (NSString *) password
               harmonyHubIPAddress: (NSString *) IPAddress
                    harmonyHubPort: (NSUInteger) port
{
    FSCHarmonyClient * client = [[self alloc] initWithMyHarmonyUsername: username
                                                      myHarmonyPassword: password
                                                    harmonyHubIPAddress: IPAddress
                                                         harmonyHubPort: port];
    
    [client setupXMPPStream];
    
    [client connectToHarmonyHub];
    
    [client startHeartbeat];
    
    return client;
}

- (void) startHeartbeat
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        
        [self setHeartbeatTimer: [NSTimer scheduledTimerWithTimeInterval: 30
                                                                  target: self
                                                                selector: @selector(sendHeartbeat:)
                                                                userInfo: nil
                                                                 repeats: YES]];
    });
}

- (void) stopHeartbeatTimer
{
    [[self heartbeatTimer] invalidate];
    [self setHeartbeatTimer: nil];
}

- (long) timestamp
{
    return [[NSDate date] timeIntervalSinceDate: [self creationTime]];
}

- (void) setCurrentActivity: (FSCActivity *) currentActivity
{
    _currentActivity = currentActivity;
    
    [[NSNotificationCenter defaultCenter] postNotificationName: FSCHarmonyClientCurrentActivityChangedNotification
                                                        object: self
                                                      userInfo: @{FSCHarmonyClientCurrentActivityChangedNotificationActivityKey: currentActivity}];
}

#pragma mark - Initialization & Connection

- (void) connectToHarmonyHub
{
    didDisconnectWhileConnecting = NO;
    isXMPPConnected = NO;
    isXMPPAuthenticated = NO;
    didXMPPFailAuthentication = NO;
    validOAResponseReceived = NO;
    [self setAuthenticationFailureError: nil];
    
    NSString * myHarmonyToken = [self requestMyHarmonyToken];
    
    [self connectAndAuthenticateXMPPStreamWithUsername: GENERAL_HARMONY_HUB_USERNAME
                                              password: GENERAL_HARMONY_HUB_PASSWORD];
    
    NSString * harmonyHubToken = [self swapMyHarmonyTokenForHarmonyHubToken: myHarmonyToken];
    
    [self disconnect];

    [self connectAndAuthenticateXMPPStreamWithUsername: [NSString stringWithFormat:
                                                         @"%@@connect.logitech.com/harmony",
                                                         harmonyHubToken]
                                              password: harmonyHubToken];
}

- (NSString *) requestMyHarmonyToken
{
    AFHTTPRequestOperationManager * manager = [AFHTTPRequestOperationManager manager];
    [manager setCompletionQueue: dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    
    [manager setRequestSerializer: [AFJSONRequestSerializer new]];
    
    NSDictionary * parameters = @{@"email": [self myHarmonyUsername],
                                  @"password": [self myHarmonyPassword]};
    
    __block NSString * myHarmonyToken = nil;
    __block BOOL asyncOperationCompleted = NO;
    __block NSError * error = nil;
    
    [manager POST: MY_HARMONY_AUTH_URL
       parameters: parameters
          success: ^(AFHTTPRequestOperation *operation, id responseObject)
     {
         NSDictionary * result = [responseObject objectForKey: @"GetUserAuthTokenResult"];
         
         if (!result)
         {
             error = [NSError errorWithDomain: FSCErrorDomain
                                         code: FSCErrorCodeUnexpectedMyHarmonyResponse
                                     userInfo: @{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                                                                             @"Could not find user auth token result keyed on 'GetUserAuthTokenResult' in JSON: %@",
                                                                             responseObject]}];
         }
         
         if (!error)
         {
             myHarmonyToken = [result objectForKey: @"UserAuthToken"];
             
             if (!myHarmonyToken)
             {
                 error = [NSError errorWithDomain: FSCErrorDomain
                                             code: FSCErrorCodeUnexpectedMyHarmonyResponse
                                         userInfo: @{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                                                                                 @"Could not find token keyed on 'UserAuthToken' in JSON: %@",
                                                                                 responseObject]}];
             }
         }
         
         asyncOperationCompleted = YES;
     }
          failure: ^(AFHTTPRequestOperation *operation, NSError *myHarmonyError)
     {
         error = [NSError errorWithDomain: FSCErrorDomain
                                     code: FSCErrorCodeUnexpectedMyHarmonyResponse
                                 userInfo: @{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                                                                         @"An error occurred in GetUserToken: %@",
                                                                         [myHarmonyError localizedDescription]]}];
         
         asyncOperationCompleted = YES;
     }];
    
    dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        
        while (!asyncOperationCompleted)
        {
            [NSThread sleepForTimeInterval: 0.25];
        }
    });
    
    if (error)
    {
        @throw [NSException exceptionWithName: FSCExceptionMyHarmonyConnection
                                       reason: [NSString stringWithFormat:
                                                @"An error occurred while requesting My Harmony token: %@",
                                                [error description]]
                                     userInfo: nil];
    }
    
    return myHarmonyToken;
}

- (void) setupXMPPStream
{
    NSAssert([self xmppStream] == nil, @"Method setupXMPPStream invoked multiple times");
    
    [self setXmppStream: [[XMPPStream alloc] init]];
    
    [[self xmppStream] addDelegate: self
                     delegateQueue: dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
    
    [[self xmppStream] setHostName: [self harmonyHubIPAddress]];
    [[self xmppStream] setHostPort: [self harmonyHubPort]];
}

- (void) connectAndAuthenticateXMPPStreamWithUsername: (NSString *) username
                                             password: (NSString *) password
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    if ([[self xmppStream] isDisconnected])
    {
        [[self xmppStream] setMyJID: [XMPPJID jidWithString: username]];
        
        NSError * error = nil;
        
        if (![[self xmppStream] connectWithTimeout: 5
                                             error: &error])
        {
            @throw [NSException exceptionWithName: FSCExceptionHarmonyHubConnection
                                           reason: [NSString stringWithFormat:
                                                    @"Could not connect to Harmony Hub: %@",
                                                    [error localizedDescription]]
                                         userInfo: nil];
        }
        
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
           
            while (!isXMPPConnected &&
                   !didDisconnectWhileConnecting)
            {
                [NSThread sleepForTimeInterval: 0.25];
            }
        });
        
        if (didDisconnectWhileConnecting)
        {
            didDisconnectWhileConnecting = NO;
            
            @throw [NSException exceptionWithName: FSCExceptionHarmonyHubConnection
                                           reason: [NSString stringWithFormat:
                                                    @"Could not connect to Harmony Hub: %@",
                                                    [error localizedDescription]]
                                         userInfo: nil];
        }
        
        if (![[self xmppStream] authenticateWithPassword: password
                                                   error: &error])
        {
            @throw [NSException exceptionWithName: FSCExceptionHarmonyHubConnection
                                           reason: [NSString stringWithFormat:
                                                    @"Could not authenticate to Harmony Hub: %@",
                                                    [error localizedDescription]]
                                         userInfo: nil];
        }
        
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            
            while (!isXMPPAuthenticated &&
                   !didXMPPFailAuthentication)
            {
                [NSThread sleepForTimeInterval: 0.25];
            }
        });
        
        if (didXMPPFailAuthentication)
        {
            [self disconnect];
            
            @throw [NSException exceptionWithName: FSCExceptionHarmonyHubConnection
                                           reason: [NSString stringWithFormat:
                                                    @"Could not authenticate to Harmony Hub: %@",
                                                    [self authenticationFailureError]]
                                         userInfo: nil];
        }
    }
    else
    {
        @throw [NSException exceptionWithName: FSCExceptionHarmonyHubConnection
                                       reason: @"XMPP Stream is already connected"
                                     userInfo: nil];
    }
}

- (NSString *) swapMyHarmonyTokenForHarmonyHubToken: (NSString *) myHarmonyToken
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    NSXMLElement * actionCmd = [[NSXMLElement alloc] initWithName: @"oa"
                                                            xmlns: @"connect.logitech.com"];
    [actionCmd addAttributeWithName: @"mime"
                        stringValue: @"vnd.logitech.connect/vnd.logitech.pair"];
    [actionCmd setStringValue: [NSString stringWithFormat:
                                @"token=%@:name=%@",
                                myHarmonyToken,
                                @"harmony#iOS6.0.1#iPhone"]];
    
    XMPPIQ * IQCmd = [XMPPIQ iqWithType: @"get"
                                  child: actionCmd];
    
    __block NSString * OAAttributesAndValuesString = nil;
    
    [self sendIQCmd: IQCmd
andWaitForValidResponse: ^BOOL(DDXMLElement *OAResponse)
    {
        OAAttributesAndValuesString = [OAResponse stringValue];
        
        return YES;
    }];
    
    NSString * harmonyHubToken = nil;
    
    if (OAAttributesAndValuesString)
    {
        NSArray * OAAttributesAndValues = [OAAttributesAndValuesString componentsSeparatedByString: @":"];
        
        for (NSString * anAttributeAndValue in OAAttributesAndValues)
        {
            NSArray * attributeAndValue = [anAttributeAndValue componentsSeparatedByString: @"="];
            
            if ([attributeAndValue count] == 2 &&
                [attributeAndValue[0] isEqualToString: @"identity"])
            {
                harmonyHubToken = attributeAndValue[1];
                
                break;
            }
        }
    }
    
    if (!harmonyHubToken)
    {
        @throw [NSException exceptionWithName: FSCExceptionHarmonyHubConnection
                                       reason: [NSString stringWithFormat:
                                                @"Unexpected pair response from HUB: %@",
                                                OAAttributesAndValuesString]
                                     userInfo: nil];
    }

    return harmonyHubToken;
}

- (void) sendIQCmd: (XMPPIQ *) IQCmd
{
    NSLog(@"%@: %@", NSStringFromSelector(_cmd), IQCmd);
    
    [[self xmppStream] sendElement: IQCmd];
}

- (void) sendIQCmd: (XMPPIQ *) IQCmd
andWaitForValidResponse: (BOOL (^)(NSXMLElement * OAResponse))responseValidationBlock;
{
    @synchronized(self)
    {
        validOAResponseReceived = NO;
        
        [self setOAResponseValidationBlock: responseValidationBlock];
        
        NSXMLElement * oaElement = [IQCmd elementForName: @"oa"];
        
        if (oaElement)
        {
            DDXMLNode * mimeNode = [oaElement attributeForName: @"mime"];
            
            if (mimeNode)
            {
                [self setExpectedOAResponseMime: [mimeNode stringValue]];
            }
        }
        
        [self sendIQCmd: IQCmd];
        
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            
            while (!validOAResponseReceived)
            {
                [NSThread sleepForTimeInterval: 0.25];
            }
        });
        
        [self setOAResponseValidationBlock: nil];
        [self setExpectedOAResponseMime: nil];
    }
}

#pragma mark - Operations

- (void) sendHeartbeat: (NSTimer *) timer
{
    if (![[self xmppStream] isConnected])
    {
        [timer invalidate];
        [self setHeartbeatTimer: nil];
    }
    else
    {
        NSLog(@"Sending heartbeat");
        
        NSXMLElement * actionCmd = [[NSXMLElement alloc] initWithName: @"oa"
                                                                xmlns: @"connect.logitech.com"];
        [actionCmd addAttributeWithName: @"mime"
                            stringValue: @"vnd.logitech.connect/vnd.logitech.ping"];
        
        XMPPIQ * IQCmd = [XMPPIQ iqWithType: @"get"
                                      child: actionCmd];
        
        [self sendIQCmd: IQCmd
andWaitForValidResponse: nil];
    }
}

- (NSString *) appendTimestampToCommand: (NSString *) command
{
    return [NSString stringWithFormat:
            @"%@:timestamp=%ld",
            command,
            [self timestamp]];
}

- (FSCHarmonyConfiguration *) configurationWithRefresh: (BOOL) refresh
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    if (![self configuration] ||
        refresh)
    {
        NSXMLElement * actionCmd = [[NSXMLElement alloc] initWithName: @"oa"
                                                                xmlns: @"connect.logitech.com"];
        [actionCmd addAttributeWithName: @"mime"
                            stringValue: @"vnd.logitech.harmony/vnd.logitech.harmony.engine?config"];
        
        XMPPIQ * iqCmd = [XMPPIQ iqWithType: @"get"
                                      child: actionCmd];
        
        __block NSString * OAString = nil;
        
        [self sendIQCmd: iqCmd
andWaitForValidResponse: ^BOOL(DDXMLElement *OAResponse)
         {
             OAString = [OAResponse stringValue];
             
             return YES;
         }];
        
        NSDictionary * configuration = nil;
        
        if (OAString)
        {
            NSData * OAStringData = [OAString dataUsingEncoding: NSUTF8StringEncoding];
            NSError * error = nil;
            
            id JSONObject =  [NSJSONSerialization JSONObjectWithData: OAStringData
                                                             options: kNilOptions
                                                               error: &error];
            
            if ([JSONObject isKindOfClass: [NSDictionary class]])
            {
                configuration = JSONObject;
            }
        }
        
        if (!configuration)
        {
            @throw [NSException exceptionWithName: FSCExceptionHarmonyHubConfiguration
                                           reason: [NSString stringWithFormat:
                                                    @"Unexpected config response from HUB: %@",
                                                    OAString]
                                         userInfo: nil];
        }
        
        FSCHarmonyConfiguration * harmonyConfig = [FSCHarmonyConfiguration modelObjectWithDictionary: configuration];
        
        [self setConfiguration: harmonyConfig];
    }
    
    return [self configuration];
}

- (FSCActivity *) currentActivityFromConfiguration: (FSCHarmonyConfiguration *) configuration
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    if (![self currentActivity])
    {
        if (!configuration)
        {
            configuration = [self configurationWithRefresh: NO];
        }
        else
        {
            [self setConfiguration: configuration];
        }
        
        NSXMLElement * actionCmd = [[NSXMLElement alloc] initWithName: @"oa"
                                                                xmlns: @"connect.logitech.com"];
        [actionCmd addAttributeWithName: @"mime"
                            stringValue: @"vnd.logitech.harmony/vnd.logitech.harmony.engine?getCurrentActivity"];
        
        XMPPIQ * IQCmd = [XMPPIQ iqWithType: @"get"
                                      child: actionCmd];
        
        __block NSString * OAString = nil;
        
        [self sendIQCmd: IQCmd
andWaitForValidResponse: ^BOOL(DDXMLElement *OAResponse)
         {
             OAString = [OAResponse stringValue];
             
             return YES;
             
         }];
        
        NSString * currentActivityId = nil;
        
        if (OAString)
        {
            NSArray * attributeAndvalue = [OAString componentsSeparatedByString: @"="];
            
            if ([attributeAndvalue count] == 2)
            {
                currentActivityId = attributeAndvalue[1];
            }
        }
        
        if (!currentActivityId)
        {
            @throw [NSException exceptionWithName: FSCExceptionHarmonyHubCurrentActivity
                                           reason: [NSString stringWithFormat:
                                                    @"Unexpected getCurrentActivity response from HUB: %@",
                                                    OAString]
                                         userInfo: nil];
        }
        
        [self setCurrentActivity: [configuration activityWithId: currentActivityId]];
    }
    
    return [self currentActivity];
}

- (void) startActivityWithId: (NSString *) activityId
{
    NSLog(@"%@ %@", NSStringFromSelector(_cmd), activityId);
    
    NSXMLElement * actionCmd = [[NSXMLElement alloc] initWithName: @"oa"
                                                            xmlns: @"connect.logitech.com"];
    [actionCmd addAttributeWithName: @"mime"
                        stringValue: @"harmony.engine?startactivity"];
    
    NSString * command = [NSString stringWithFormat:
                          @"activityId=%@",
                          activityId];
    command = [self appendTimestampToCommand: command];
    
    [actionCmd setStringValue: command];
    
    XMPPIQ * IQCmd = [XMPPIQ iqWithType: @"get"
                                  child: actionCmd];
    
    [self sendIQCmd: IQCmd
andWaitForValidResponse: nil];
}

- (void) startActivity: (FSCActivity *) activity
{
    [self startActivityWithId: [activity activityIdentifier]];
    
    [self setCurrentActivity: activity];
}

- (void) executeFunction: (FSCFunction *) function
                withType: (FSCHarmonyClientFunctionType) type
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    NSXMLElement * actionCmd = [[NSXMLElement alloc] initWithName: @"oa"
                                                            xmlns: @"connect.logitech.com"];
    [actionCmd addAttributeWithName: @"mime"
                        stringValue: @"vnd.logitech.harmony/vnd.logitech.harmony.engine?holdAction"];
    
    NSString * typeStr = (type == FSCHarmonyClientFunctionTypePress) ? @"press" : @"release";
    
    NSString * reformattedAction = [[function action] stringByReplacingOccurrencesOfString: @":"
                                                                                withString: @"::"];
    
    [actionCmd setStringValue: [NSString stringWithFormat:
                                @"action=%@:status=%@",
                                reformattedAction,
                                typeStr]];
    
    XMPPIQ * IQCmd = [XMPPIQ iqWithType: @"get"
                                  child: actionCmd];
    
    [self sendIQCmd: IQCmd
andWaitForValidResponse: nil];
}

- (void) turnOff
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    [self startActivity: [[self configurationWithRefresh: NO] activityWithId: @"-1"]];
}

- (void) disconnect
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    [self stopHeartbeatTimer];
    
    if (![[self xmppStream] isDisconnected])
    {
        [[self xmppStream] disconnect];
        
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            
            while (isXMPPConnected)
            {
                [NSThread sleepForTimeInterval: 0.25];
            }
        });
    }
}

#pragma mark XMPPStream Delegate

- (void) xmppStreamDidConnect: (XMPPStream *) sender
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    isXMPPConnected = YES;
}

- (void) xmppStreamDidAuthenticate: (XMPPStream *) sender
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    isXMPPAuthenticated = YES;
}

- (void) xmppStream:(XMPPStream *) sender
 didNotAuthenticate: (NSXMLElement *) error
{
    NSLog(@"%@ %@", NSStringFromSelector(_cmd), error);
    
    didXMPPFailAuthentication = YES;
    
    [self setAuthenticationFailureError: error];
}

- (BOOL) xmppStream: (XMPPStream *) sender
       didReceiveIQ: (XMPPIQ *) iq
{
    NSLog(@"%@: %@", NSStringFromSelector(_cmd), iq);
    
    NSXMLElement * oaResponse = [iq elementForName: @"oa"];
    
    BOOL validOAResponse = NO;
    
    if ([self OAResponseValidationBlock])
    {
        if (oaResponse &&
            [self OAResponseValidationBlock](oaResponse))
        {
            if ([self expectedOAResponseMime])
            {
                DDXMLNode * mimeNode = [oaResponse attributeForName: @"mime"];
                
                if (mimeNode)
                {
                    NSString * mimeResponse = [mimeNode stringValue];
                    
                    validOAResponse = [mimeResponse isEqualToString: [self expectedOAResponseMime]];
                }
            }
            else
            {
                validOAResponse = YES;
            }
        }
    }
    else
    {
        validOAResponse = YES;
    }
    
    validOAResponseReceived = validOAResponse;
    
    return NO;
}

- (void) xmppStream: (XMPPStream *) sender
    didReceiveError: (id) error
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
}

- (void) xmppStreamDidDisconnect: (XMPPStream *) sender
                       withError: (NSError *) error
{
    NSLog(@"%@ %@", NSStringFromSelector(_cmd), [error localizedDescription]);
    
    [self stopHeartbeatTimer];
    
    if (!isXMPPConnected)
    {
        didDisconnectWhileConnecting = YES;
    }
    
    isXMPPConnected = NO;
    isXMPPAuthenticated = NO;
}

@end
