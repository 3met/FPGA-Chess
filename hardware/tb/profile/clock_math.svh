// Normalize using positive remainders so elaborators agree on negative phases.
function automatic int normalized_phase_ps(input int phase_ps, input int period_ps);
    if (phase_ps >= 0) return phase_ps % period_ps;
    return (period_ps - ((-phase_ps) % period_ps)) % period_ps;
endfunction

// Widen before multiplication and round to the shared picosecond grid.
function automatic int clock_high_ps(input int period_ps, input int duty_percent);
    return int'((longint'(period_ps) * duty_percent + 50) / 100);
endfunction
