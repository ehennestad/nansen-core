function result = imageFrame(data, frame, channel, projection, limits, plane)
%imageFrame A frame of an image or stack, as 8-bit values for the dashboard's viewer
%
%   data is height x width (x frames), height x width x channels x frames,
%   or height x width x channels x planes x frames: an array, or a
%   nansen.Stack read a chunk of frames at a time. frame, channel and
%   plane are 0-based; projection is "", "mean", "max", "min",
%   "std", "correlation" (each pixel's with its 8 neighbours) or "peakTime"
%   (the frame of each pixel's peak, with brightness: its peak, 8-bit); limits is [] or [low, high]. Values from low to high are scaled
%   to 0..255 as floor((v - low) / (high - low) * 255 + 0.5), cut at both
%   ends; NaN is 0. low and high are the limits given, or else the smallest
%   and largest finite value of the frame. pixels is base64 of the bytes,
%   row after row. Python's nansen.frames.image_frame gives the same bytes.
    if nargin < 6
        plane = 0;
    end
    [stack, channels, planes] = nansen.internal.pickChannel(data, channel, plane);
    [height, width, frames] = size(stack);
    chunk = 100;   % frames read at a time for a projection
    switch projection
        case "mean"
            image = nansen.internal.meanImage(stack);
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
        case "min"
            image = [];
            for start = 1:chunk:frames
                bottom = min(stack.frames(start, start + chunk - 1), [], 3);
                if isempty(image)
                    image = bottom;
                else
                    image = min(image, bottom);
                end
            end
            image = double(image);
            frame = [];
        case "peakTime"   % the frame of each pixel's peak (the first, on a tie); its peak is the brightness
            peak = [];
            when = [];
            for start = 1:chunk:frames
                [here, at] = max(double(stack.frames(start, start + chunk - 1)), [], 3);
                at = at + start - 2;   % 0-based frames
                if isempty(peak)
                    peak = here;
                    when = at;
                else
                    later = here > peak;
                    peak(later) = here(later);
                    when(later) = at(later);
                end
            end
            image = double(when);
            frame = [];
            if isempty(limits)
                limits = [0, max(frames - 1, 1)];
            end
        case "std"
            image = nansen.internal.stdImage(stack);
            frame = [];
        case "correlation"
            image = nansen.internal.localCorrelation(stack);
            frame = [];
        case ""
            if frame < 0 || frame >= frames || frame ~= round(frame)
                nansen.internal.throwError("invalid-params", "there are %d frames; frame %d is not one", frames, frame)
            end
            image = double(stack.frames(frame + 1, frame + 1));
        otherwise
            nansen.internal.throwError("invalid-params", "projection is mean, max, min, std, correlation or peakTime, not '%s'", projection)
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
    result = struct("height", height, "width", width, "frames", frames, "channels", channels, "planes", planes, "frame", frame, ...
        "low", low, "high", high, "pixels", matlab.net.base64encode(reshape(scaled.', 1, [])));
    if projection == "peakTime"   % the peaks, as 8-bit values from the smallest to the largest
        finite = peak(isfinite(peak));
        bright = zeros(height, width, "uint8");
        if ~isempty(finite) && max(finite) > min(finite)
            values = floor((peak - min(finite)) / (max(finite) - min(finite)) * 255 + 0.5);
            values(isnan(values)) = 0;
            bright = uint8(min(max(values, 0), 255));
        end
        result.brightness = matlab.net.base64encode(reshape(bright.', 1, []));
    end
end
