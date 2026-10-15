function [stack, channels, planes] = pickChannel(data, channel, plane)
%pickChannel The channel and plane (0-based) of an image or stack, as a height x width x frames nansen.Stack
%
%   data is height x width (x frames), x channels x frames or x channels x
%   planes x frames: an array or a nansen.Stack. channels and planes are
%   how many it has. As Python's nansen.frames._pick.
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
    channels = 1;
    planes = 1;
    if ndims(stack) >= 4
        channels = size(stack, 3);
    end
    if ndims(stack) == 5
        planes = size(stack, 4);
        if plane < 0 || plane >= planes
            nansen.internal.throwError("invalid-params", "there are %d planes; plane %d is not one", planes, plane)
        end
        stack = stack.select(4, plane + 1);
    elseif plane ~= 0
        nansen.internal.throwError("invalid-params", "there is 1 plane; plane %d is not one", plane)
    end
    if ndims(stack) == 4
        if channel < 0 || channel >= channels
            nansen.internal.throwError("invalid-params", "there are %d channels; channel %d is not one", channels, channel)
        end
        stack = stack.select(3, channel + 1);
    end
end
