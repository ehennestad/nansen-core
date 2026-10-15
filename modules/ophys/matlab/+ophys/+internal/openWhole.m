function stack = openWhole(context, entity, name, options, per)
%openWhole The variable as a nansen.Stack of all its axes, height x width (x channels (x planes)) x frames
%
%   An image is one frame. Read a chunk at a time, of the options' frames
%   firstFrame..lastFrame only (from 1; lastFrame 0 for the last), per frames
%   of the variable to each of them (deinterleave's channels x planes). A
%   range that is empty or not within the stack is invalid-options. In a
%   preview, the range is cut to its first frames. As Python's _open_whole.
    if nargin < 4
        options = struct();
    end
    if nargin < 5
        per = 1;
    end
    first = double(nansen.internal.getField(options, "firstFrame", 1));
    last = double(nansen.internal.getField(options, "lastFrame", 0));
    if first < 1 || last < 0 || (last > 0 && last < first)
        nansen.internal.throwError("invalid-options", ...
            "frames %d to %d are no frames: firstFrame is from 1, and lastFrame 0 (the last) or from firstFrame", first, last)
    end
    stack = context.Project.openStack(entity, name);
    if ndims(stack) == 2
        limit = stack.MaxFrames;
        stack.MaxFrames = Inf;   % an image's columns are not frames
        stack = nansen.Stack.fromArray(stack.all(), 3);   % an image: one frame
        stack.MaxFrames = limit;
        if first > 1 || last > 1
            nansen.internal.throwError("invalid-options", "%s is an image, one frame; frames %d to %d are not frames of it", name, first, last)
        end
        return
    end
    if first == 1 && last == 0
        return
    end
    stop = Inf;
    if last > 0
        stop = last * per;
    end
    try
        stack = context.Project.openStack(entity, name, [(first - 1) * per + 1, stop]);
    catch err
        if ~isa(err, "nansen.NansenError") || err.Code ~= "invalid-params"
            rethrow(err)
        end
        nansen.internal.throwError("invalid-options", "%s: %s", name, extractAfter(string(err.message), "] "))
    end
end
