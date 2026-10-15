function frames = recastFrames(frames, outputType, low, high)
%recastFrames Aligned frames as outputType: the same, or uint8 or uint16 scaled from low..high to the type's full range, rounded half up
    if outputType == "same"
        return
    end
    top = double(intmax(outputType));
    if ~(high > low)
        frames = zeros(size(frames), outputType);
        return
    end
    frames = cast(min(max(floor((double(frames) - low) / (high - low) * top + 0.5), 0), top), outputType);
end
