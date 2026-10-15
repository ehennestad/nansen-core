function [image, frame, limits, binned, peak] = shownImage(stack, frame, projection, limits, bin)
%shownImage The image the viewer shows of one channel and plane of a stack, as doubles
%
%   A frame (0-based), the frame binned with those around it (bin: struct
%   size, method, or []; imviewer's binning) or a projection ("mean",
%   "max", "min", "std", "correlation", "globalCorrelation", "meanClahe" or
%   "peakTime"; "" for the frame). Also the frame ([] for a projection),
%   the limits (peakTime's own when [] are given), the frames binned
%   ([first, stop) from 0, or []) and peakTime's peaks. Python's
%   nansen.frames.shown_image gives the same.
    if nargin < 4
        limits = [];
    end
    if nargin < 5
        bin = [];
    end
    binned = [];
    peak = [];
    [~, ~, frames] = size(stack);
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
        case "globalCorrelation"
            image = nansen.internal.globalCorrelation(stack);
            frame = [];
        case "meanClahe"
            image = nansen.internal.meanClahe(stack);
            frame = [];
        case ""
            if frame < 0 || frame >= frames || frame ~= round(frame)
                nansen.internal.throwError("invalid-params", "there are %d frames; frame %d is not one", frames, frame)
            end
            if isempty(bin)
                image = double(stack.frames(frame + 1, frame + 1));
            else   % imviewer's binning: the mean or max of the frames around the frame
                [first, stop] = movingWindow(frame, bin.size, frames);
                part = double(stack.frames(first + 1, stop));
                if string(bin.method) == "max"
                    image = max(part, [], 3);
                else
                    image = sum(part, 3) / (stop - first);
                end
                binned = [first, stop];
            end
        otherwise
            nansen.internal.throwError("invalid-params", "projection is mean, max, min, std, correlation, globalCorrelation, meanClahe or peakTime, not '%s'", projection)
    end
end

function [first, stop] = movingWindow(frame, size, frames)
    % The frames binned around frame (from 0; [first, stop)), as dev's getMovingWindowFrameIndices and Python's moving_window
    number = frame + 1;
    half = ceil(size / 2);
    if number <= half
        first = 0;
        stop = min(frames, size);
    elseif frames - number < half
        first = max(frames - size + 1, 1) - 1;
        stop = frames;
    else
        first = number - floor(size / 2) - 1;
        stop = number + floor(size / 2);
    end
end
