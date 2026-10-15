function value = numFrames(sessionObject)
%NUMFRAMES Get value for numFrames
%   A table variable with an update function, as dev's TemplateFunction makes one.

    % Initialize output value with the default value.
    value = nan;                 % Please do not edit this line

    % Return default value if no input is given (used during config).
    if nargin < 1; return; end	% Please do not edit this line

    % Insert your code here:
    value = strlength(string(sessionObject.Key.session_id));
end
