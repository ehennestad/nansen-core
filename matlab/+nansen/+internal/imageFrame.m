function result = imageFrame(data, frame, channel, projection, limits)
%imageFrame A frame of an image or stack, as 8-bit values for the dashboard's viewer
%
%   data is height x width (x frames), or height x width x channels x
%   frames. frame and channel are 0-based; projection is "", "mean" or
%   "max"; limits is [] or [low, high]. Values from low to high are scaled
%   to 0..255 as floor((v - low) / (high - low) * 255 + 0.5), cut at both
%   ends; NaN is 0. low and high are the limits given, or else the smallest
%   and largest finite value of the frame. pixels is base64 of the bytes,
%   row after row. Python's nansen.frames.image_frame gives the same bytes.
    if ~(isnumeric(data) || islogical(data)) || ~isreal(data) || ndims(data) > 4
        nansen.internal.throwError("invalid-data", "the data is not an image or a stack of images")
    end
    if ndims(data) == 4
        if channel < 0 || channel >= size(data, 3)
            nansen.internal.throwError("invalid-params", "there are %d channels; channel %d is not one", size(data, 3), channel)
        end
        data = reshape(data(:, :, channel + 1, :), size(data, 1), size(data, 2), []);
    end
    [height, width, frames] = size(data);
    switch projection
        case "mean"
            image = mean(double(data), 3);
            frame = [];
        case "max"
            image = double(max(data, [], 3));
            frame = [];
        case ""
            if frame < 0 || frame >= frames || frame ~= round(frame)
                nansen.internal.throwError("invalid-params", "there are %d frames; frame %d is not one", frames, frame)
            end
            image = double(data(:, :, frame + 1));
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
