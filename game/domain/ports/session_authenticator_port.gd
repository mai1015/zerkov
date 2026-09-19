class_name ZSessionAuthenticatorPort
extends RefCounted
## Trusted server-side seam that exchanges a credential for credential-free claims.
##
## Implementations must fail closed and must not use a client claim as proof of
## profile or actor ownership. Product admission erases the credential after this
## call and persists only the returned grant.

func authenticate(_request: ZSessionRequest) -> ZSessionAuthGrant:
	return null
