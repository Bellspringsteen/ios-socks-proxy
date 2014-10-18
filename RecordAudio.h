#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>


@class RecordAudio;


@interface RecordAudio : NSObject<AVAudioSessionDelegate>{
	
	BOOL working;
    BOOL                        _useCustomPayload;
	AURenderCallbackStruct		inputProc;
	AURenderCallbackStruct		outputProc;
    AVAudioSession              * session;
    
	AUGraph                     decodingGraph;
    
	BOOL						start;
    BOOL                        initialized;
	BOOL						running;
    
	BOOL						unitIsRunning;
	BOOL						unitHasBeenCreated;
    
}

- (void) start;
- (void) stop;
- (void) reset;

@property (nonatomic, assign)	AUGraph                 decodingGraph;
@property (nonatomic, assign)	BOOL					unitIsRunning;
@property (nonatomic, assign)	BOOL					unitHasBeenCreated;
@property (nonatomic, assign)	AURenderCallbackStruct	inputProc;
@property (nonatomic, assign)   BOOL                    useCustomPayload;


@end
