function stack = openStack(context, entity, name, options)
%openStack The variable as a height x width x frames nansen.Stack read a chunk at a time (an image is one frame)
%
%   A stack with channels (height x width x channels x frames) or planes too
%   (x channels x planes x frames) gives the options' channel and plane
%   (1-based; the first when there is no such option). Only the options'
%   frames firstFrame..lastFrame are given (ophys.internal.openWhole).
    if nargin < 4
        options = struct();
    end
    stack = ophys.internal.pick(ophys.internal.openWhole(context, entity, name, options), name, ...
        double(nansen.internal.getField(options, "channel", 1)), double(nansen.internal.getField(options, "plane", 1)));
end
