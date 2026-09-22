import Foundation
import AVFoundation
import AudioToolbox

class OpenBSTAudioUnit: AUAudioUnit {
    var provider: OpenBSTSpeechProvider?
    
    override var internalRenderBlock: AUInternalRenderBlock {
        return { [weak self] (actionFlags, timestamp, frameCount) -> AUAudioUnitStatus in
            guard let self = self, let provider = self.provider else {
                return noErr
            }
            
            // 1. Get the output buffer for the first (and only) output bus
            guard let outputBus = self.outputBuses[0],
                  let buffer = outputBus.buffer else {
                return noErr
            }
            
            // 2. Fetch the channel data (Mono)
            guard let channelData = buffer.floatChannelData?[0] else {
                return noErr
            }
            
            // 3. Fill the buffer from the provider
            let written = provider.fillBuffer(channelData, frames: Int(frameCount))
            
            // 4. Signal if we've reached the end of the speech
            if written < Int(frameCount) {
                // We've run out of samples
                // In a real AU, we might set a flag or update a property to signal completion
            }
            
            return noErr
        }
    }
}
