package pl.krakowbezbarier.api.auth;

import org.springframework.http.HttpStatus;
import org.springframework.security.core.context.SecurityContextHolder;
import pl.krakowbezbarier.api.common.ApiException;

import java.util.UUID;

public final class CurrentUser {
    private CurrentUser() {}

    /** The authenticated user, or null on public endpoints called without a (valid) token. */
    public static UUID optional() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        return auth != null && auth.getPrincipal() instanceof UUID id ? id : null;
    }

    public static UUID id() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof UUID id) return id;
        throw new ApiException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "Missing or invalid token");
    }
}
