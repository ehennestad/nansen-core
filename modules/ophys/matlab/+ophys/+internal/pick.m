function stack = pick(stack, name, channel, plane)
%pick One channel and plane (1-based) of a 3-, 4- or 5-dimensional nansen.Stack, as height x width x frames (still lazy)
    channels = 1;
    planes = 1;
    if ndims(stack) >= 4
        channels = size(stack, 3);
    end
    if ndims(stack) == 5
        planes = size(stack, 4);
    end
    if ndims(stack) > 5
        nansen.internal.throwError("invalid-data", "%s is %s; a stack is height x width (x channels (x planes)) x frames", name, mat2str(size(stack)))
    end
    if channel < 1 || channel > channels || channel ~= round(channel)
        nansen.internal.throwError("invalid-options", "%s has %d channel%s; channel %d is not one", name, channels, plural(channels), channel)
    end
    if plane < 1 || plane > planes || plane ~= round(plane)
        nansen.internal.throwError("invalid-options", "%s has %d plane%s; plane %d is not one", name, planes, plural(planes), plane)
    end
    if ndims(stack) == 5
        stack = stack.select(4, plane).select(3, channel);
    elseif ndims(stack) == 4
        stack = stack.select(3, channel);
    end
end

function s = plural(n)
    s = "";
    if n > 1
        s = "s";
    end
end
