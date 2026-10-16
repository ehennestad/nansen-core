function executable = pythonExecutable()
%pythonExecutable The Python that runs NANSEN's Python side from a MATLAB method (nansen.internal.runInPython)
%
%   The executable in the NANSEN_PYTHON environment variable, else the
%   Python MATLAB's pyenv is set to, else python3 (python on Windows) on
%   the system path.
    executable = string(getenv("NANSEN_PYTHON"));
    if executable ~= ""
        return
    end
    try
        executable = string(pyenv().Executable);
        executable = executable(1:min(end, 1));
    catch
        executable = "";
    end
    if isempty(executable) || ismissing(executable(1)) || executable(1) == ""
        executable = "python3";
        if ispc
            executable = "python";
        end
    end
end
