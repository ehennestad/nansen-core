function result = imageFrame(data, frame, channel, projection, limits, plane)
%imageFrame A frame of an image or stack, as 8-bit values for the dashboard's viewer
%
%   data is height x width (x frames), height x width x channels x frames,
%   or height x width x channels x planes x frames: an array, or a
%   nansen.Stack read a chunk of frames at a time. frame, channel and
%   plane are 0-based; projection is "", "mean" or
%   "max"; limits is [] or [low, high]. Values from low to high are scaled
%   to 0..255 as floor((v - low) / (high - low) * 255 + 0.5), cut at both
%   ends; NaN is 0. low and high are the limits given, or else the smallest
%   and largest finite value of the frame. pixels is base64 of the bytes,
%   row after row. Python's nansen.frames.image_frame gives the same bytes.
    if nargin < 6
        plane = 0;
    end
    if isa(data, "nansen.Stack")
        stack = data;
        if ndims(stack) == 2
            stack.MaxFrames = Inf;   % an image's columns are not frames
            stack = nansen.Stack.fromArray(stack.all(), 3);   % an image: one frame
        end
    else
        if ~(isnumeric(data) || islogical(data)) || ~isreal(data) || ndims(data) > 5 || isscalar(data)
            nansen.internal.throwError("invalid-data", "the data is not an image or a stack of images")
        end
        stack = nansen.Stack.fromArray(data, max(3, ndims(data)));
    end
    if ndims(stack) > 5 || ~ismember(stack.ClassName, ["logical", "uint8", "int8", "uint16", "int16", ...
            "uint32", "int32", "uint64", "int64", "single", "double"])
        nansen.internal.throwError("invalid-data", "the data is not an image or a stack of images")
    end
    if ndims(stack) == 5
        if plane < 0 || plane >= size(stack, 4)
            nansen.internal.throwError("invalid-params", "there are %d planes; plane %d is not one", size(stack, 4), plane)
        end
        stack = stack.select(4, plane + 1);
    elseif plane ~= 0
        nansen.internal.throwError("invalid-params", "there is 1 plane; plane %d is not one", plane)
    end
    if ndims(stack) == 4
        if channel < 0 || channel >= size(stack, 3)
            nansen.internal.throwError("invalid-params", "there are %d channels; channel %d is not one", size(stack, 3), channel)
        end
        stack = stack.select(3, channel + 1);
    end
    [height, width, frames] = size(stack);
    chunk = 100;   % frames read at a time for a projection
    switch projection
        case "mean"
            total = zeros(height, width);
            for start = 1:chunk:frames
                total = total + sum(double(stack.frames(start, start + chunk - 1)), 3);
            end
            image = total / frames;
            frame = [];
        case "max"
            image = [];
            for start = 1:chunk:frames
                peak = max(stack.frames(start, start + chunk - 1), [], 3);
                if isempty(image)
                    image = peak;
                else
                    image = max(image, peak);
                end
            end
            image = double(image);
            frame = [];
        case ""
            if frame < 0 || frame >= frames || frame ~= round(frame)
                nansen.internal.throwError("invalid-params", "there are %d frames; frame %d is not one", frames, frame)
            end
            image = double(stack.frames(frame + 1, frame + 1));
        otherwise
            nansen.internal.throwError("invalid-params", "projection is mean or max, not '%s'", projection)
    end
    if isempty(limits)
        finite = image(isfinite(image));
        low = 0;
        high = 0;
        if ~isempty(finite)
            low = min(finite);
            high = max(finite);
        end
    else
        low = limits(1);
        high = limits(2);
    end
    scaled = zeros(height, width, "uint8");
    if high > low
        values = floor((image - low) / (high - low) * 255 + 0.5);
        values(isnan(values)) = 0;
        scaled = uint8(min(max(values, 0), 255));
    end
    result = struct("height", height, "width", width, "frames", frames, "frame", frame, ...
        "low", low, "high", high, "pixels", matlab.net.base64encode(reshape(scaled.', 1, [])));
end
