package pl.krakowbezbarier.api.auth;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Date;
import java.util.HexFormat;
import java.util.UUID;

/** HS256 tokens; the secret comes from env JWT_SECRET. */
@Service
public class JwtService {
    private static final Logger log = LoggerFactory.getLogger(JwtService.class);
    private final SecretKey key;
    private final Duration ttl;

    public JwtService(@Value("${app.jwt.secret:}") String secret, @Value("${app.jwt.ttl-days:30}") int ttlDays) {
        byte[] material;
        if (secret == null || secret.isBlank()) {
            log.warn("JWT_SECRET is not set - using a random secret; tokens will not survive a restart");
            material = new byte[32];
            new SecureRandom().nextBytes(material);
        } else {
            // SHA-256 so that any secret length yields a valid 256-bit HS256 key
            material = sha256(secret.getBytes(StandardCharsets.UTF_8));
        }
        this.key = Keys.hmacShaKeyFor(material);
        this.ttl = Duration.ofDays(ttlDays);
    }

    public String issue(UUID userId) {
        Instant now = Instant.now();
        return Jwts.builder().subject(userId.toString())
                .issuedAt(Date.from(now)).expiration(Date.from(now.plus(ttl)))
                .signWith(key, Jwts.SIG.HS256).compact();
    }

    /** @return user id or null when invalid / expired. */
    public UUID verify(String token) {
        try {
            String sub = Jwts.parser().verifyWith(key).build().parseSignedClaims(token).getPayload().getSubject();
            return UUID.fromString(sub);
        } catch (Exception e) {
            return null;
        }
    }

    public static byte[] sha256(byte[] in) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(in);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    public static String sha256Hex(String in) {
        return HexFormat.of().formatHex(sha256(in.getBytes(StandardCharsets.UTF_8)));
    }
}
