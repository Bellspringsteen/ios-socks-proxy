#import "RecordAudio.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>

#define SAMPLER_RATE            44100.0
#define SAMPLER_DURATION        0.023219

BOOL _restartingAudio;
BOOL _gListening;

#pragma mark C Prototypes

void SilenceData(AudioBufferList * inData);
void propListener(void *inClientData, AudioSessionPropertyID inID,
                  UInt32 inDataSize, const void *inData);

static OSStatus	PerformThru(void *inRefCon,AudioUnitRenderActionFlags
							*ioActionFlags,const AudioTimeStamp *inTimeStamp,UInt32
							inBusNumber,UInt32 inNumberFrames,AudioBufferList	*ioData);

#pragma mark C Functions

void SilenceData(AudioBufferList * inData) {
	for (UInt32 p=0; p < inData->mNumberBuffers; p++)
		memset(inData->mBuffers[p].mData, 0, inData->mBuffers[p].mDataByteSize);
}

void propListener(void * inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void * inData) {
	NSLog(@"AUDIO CHANGE: Prop Listener");
	RecordAudio * THIS = (RecordAudio *)inClientData;
	if (inID == kAudioSessionProperty_AudioRouteChange) {
        UInt32 isAudioInputAvailable;
        UInt32 size = sizeof(isAudioInputAvailable);
        AudioSessionGetProperty(kAudioSessionProperty_AudioInputAvailable,
                                &size, &isAudioInputAvailable);
        
        if (!isAudioInputAvailable) {
            [THIS performSelectorOnMainThread:@selector(stop) withObject:nil waitUntilDone:NO];
        } else if (isAudioInputAvailable) {
            [THIS performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:YES];
        }
    }
}


@interface RecordAudio ()
{
    BOOL                        _runningBeforeInteruption;
	NSTimer *                   _checkConfigTimer;
    
}

@property (nonatomic, retain) NSTimer * checkConfigTimer;

- (void)initializeAudio;
- (void) reset;

@end


@implementation RecordAudio

@synthesize decodingGraph;
@synthesize unitIsRunning;
@synthesize unitHasBeenCreated;
@synthesize inputProc;
- (id) init {
	if ((self = [super init])) {
	}
	
	return self;
}
- (void) dealloc {
    
	[self.checkConfigTimer invalidate];
	self.checkConfigTimer = nil;
    [super dealloc];
}




- (void) start{
	
    @synchronized(self) {
        [self reset];
        NSLog(@"AUDIO CHANGE: Start Listening");
        
        if (!initialized) {
            NSLog(@"initialize audio");
            [self initializeAudio];
        }
        
        // If initialization failed then try again in 60 seconds. "
        if (!initialized) {
            NSLog(@"Creating 60 seconds retry loop");
            [self performSelector:@selector(start) withObject:nil afterDelay:60];
        }
        
        
        OSStatus status = 0;
        uint32_t override = 1;
        uint32_t doChangeDefaultRoute = true;
        
        status = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker,
                                         sizeof(doChangeDefaultRoute),
                                         &doChangeDefaultRoute);
        status = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(override), &override);
        status = AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, propListener, self);
        // Make sure override wasn't changed as we passed a reference in the previous call.
        override = 1;
        //status = AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput, sizeof(override), &override);
        
        // Ensure session is active before running the graph to prevent Audio Unit init errors.
        [session setActive:YES error:nil];
        Boolean graphRunning = false;
        AUGraphIsRunning(decodingGraph, &graphRunning);
        
        if (!graphRunning) {
            AUGraphStart(decodingGraph);
        }
        running = YES;
        _gListening = YES;
    }
}

- (void) stop {
    
    @synchronized(self) {
        if(_gListening == NO)
            return;
        
        _gListening = NO;
        [self.checkConfigTimer invalidate];
        self.checkConfigTimer = nil;
        running = NO;
        Boolean graphRunning = false;
        
        OSStatus status = AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, propListener, self);
        status = AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioCategory, propListener, self);
        AUGraphIsRunning(decodingGraph, &graphRunning);
        if (graphRunning) {
            AUGraphStop(decodingGraph);
        }
        [session setActive:NO error:nil];
    }
}


#pragma mark Audio Initialization

- (void) cleanup {
	if (session) {
		AUGraphClose(decodingGraph);
		DisposeAUGraph(decodingGraph);
		decodingGraph = nil;
		
		[session setActive:NO error:nil];
		[session release];
		session = nil;
	}
	
	initialized = NO;
}

- (void) initializeAudio {
	NSLog(@"AUDIO CHANGE: Initializing");
	//First cleanup
	[self cleanup];
	
	inputProc.inputProc = PerformThru;
	inputProc.inputProcRefCon = self;
	
    initialized = NO;
    
	// Initialize audio session
	
    NSError *error = nil;
    
    session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    [session setPreferredHardwareSampleRate:SAMPLER_RATE error:&error];
    [session setPreferredIOBufferDuration:SAMPLER_DURATION error:&error];
    [session setDelegate:self];
    
    UInt32 audioCategory = kAudioSessionCategory_PlayAndRecord;  //Many options including play - maybe later
    AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory);
    
    uint32_t override = 1;
    uint32_t doChangeDefaultRoute = true;
    
    AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker,
                            sizeof(doChangeDefaultRoute),
                            &doChangeDefaultRoute);
    AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryMixWithOthers, sizeof(override), &override);
    
    if (error != nil) {
        return;
    }
    
    // Create component description for audio unit
    AudioComponentDescription ioDescription;
    ioDescription.componentType = kAudioUnitType_Output;
    ioDescription.componentSubType = kAudioUnitSubType_RemoteIO;
    ioDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    ioDescription.componentFlags = 0;
    ioDescription.componentFlagsMask = 0;
    
    // Create audio graph
    NewAUGraph(&decodingGraph);
    
    // Add node to graph represent audio unit
    AUNode ioNode;
    AUGraphAddNode(decodingGraph, &ioDescription, &ioNode);
    AUGraphOpen(decodingGraph);
    
    // Get reference to audio unit
    AudioUnit ioUnit;
    AUGraphNodeInfo(decodingGraph, ioNode, NULL, &ioUnit);
    
    //AUGraphSetNodeInputCallback(decodingGraph, ioNode, 1, &renderCallbackStruct);
    OSStatus status = 0;
    uint32_t enableInput = 1;
    status = AudioUnitSetProperty(ioUnit,kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, sizeof(enableInput));
    status = AudioUnitSetProperty(ioUnit, kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input, 0, &inputProc,
                                  sizeof(inputProc));
    
    AudioStreamBasicDescription outFormat;
    FillOutASBDForLPCM(outFormat, SAMPLER_RATE, 1, 16, 16, false, false);
    AudioUnitSetProperty(ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFormat, sizeof(outFormat));
    AudioUnitSetProperty(ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &outFormat, sizeof(outFormat));
    
    Boolean updated = YES;
    AUGraphUpdate(decodingGraph, &updated);
    
    OSStatus result = AUGraphInitialize(decodingGraph);
    if (result) {
        AUGraphClose(decodingGraph);
        DisposeAUGraph(decodingGraph);
        return;
    }

    initialized = YES;
    
    // Session Notifications
    if ([[[UIDevice currentDevice] systemVersion] floatValue] >= 6.0)
    {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioSessionInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    }
    
    
    return;
}

#pragma mark AVAudioSession delegate methods and notification handlers

- (void) audioSessionInterruption:(NSNotification *) notification
{
	NSLog(@"AUDIO CHANGE: Interrupted %@", notification);
	NSDictionary *userInfo = [notification userInfo];
    
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)[[userInfo
                                                                            objectForKey:AVAudioSessionInterruptionTypeKey]
                                                                           unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        [self stop];
    } else {
        [self start];
    }
}

#pragma mark Render Callback

static OSStatus	PerformThru(void * inRefCon,
							AudioUnitRenderActionFlags * ioActionFlags,
							const AudioTimeStamp * inTimeStamp,
							UInt32 inBusNumber,
							UInt32 inNumberFrames,
							AudioBufferList * ioData) {
	RecordAudio * THIS = (RecordAudio *)inRefCon;
	AUNode ioNode;
    AUGraphGetIndNode(THIS->decodingGraph, 0, &ioNode);
    AudioUnit ioUnit;
    AUGraphNodeInfo(THIS->decodingGraph, ioNode, NULL, &ioUnit);
    
	if (!THIS->running) {
        return noErr;
	}
    
    OSStatus err = AudioUnitRender(ioUnit, ioActionFlags,
								   inTimeStamp, 1, inNumberFrames, ioData);
    if (err) {
        NSLog(@"PerformThru: error %d\n", (int)err);
		return err;
	}
    
	SilenceData(ioData);
	
	return noErr;
}

@end
