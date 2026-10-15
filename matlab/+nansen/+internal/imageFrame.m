function result = imageFrame(data, frame, channel, projection, limits, plane, filter, bin)
%imageFrame A frame of an image or stack, as 8-bit values for the dashboard's viewer
%
%   data is height x width (x frames), height x width x channels x frames,
%   or height x width x channels x planes x frames: an array, or a
%   nansen.Stack read a chunk of frames at a time. frame, channel and
%   plane are 0-based; projection is "", "mean", "max", "min",
%   "std", "correlation" (each pixel's with its 8 neighbours), "globalCorrelation"
%   (each pixel's with the frame's mean), "meanClahe" (dev's Mean CLAHE) or "peakTime"
%   (the frame of each pixel's peak, with brightness: its peak, 8-bit); limits is [] or [low, high]. Values from low to high are scaled
%   to 0..255 as floor((v - low) / (high - low) * 255 + 0.5), cut at both
%   ends; NaN is 0. low and high are the limits given, or else the smallest
%   and largest finite value of the frame. pixels is base64 of the bytes,
%   row after row. Python's nansen.frames.image_frame gives the same bytes.
%   bin (struct size, method, or []): instead of the frame, the mean or max
%   of the frames around it (imviewer's binning), as binned [first, stop) from 0.
    if nargin < 6
        plane = 0;
    end
    if nargin < 7
        filter = "";
    end
    if nargin < 8
        bin = [];
    end
    [stack, channels, planes] = nansen.internal.pickChannel(data, channel, plane);
    [height, width, frames] = size(stack);
    [image, frame, limits, binned, peak] = nansen.internal.shownImage(stack, frame, projection, limits, bin);
    if strlength(string(filter)) > 0
        image = nansen.internal.filterImage(image, filter);
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
    if ~isempty(binned)
        result.binned = binned;
    end
end
