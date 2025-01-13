package search

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/moov-io/base/log"
	"github.com/moov-io/watchman/pkg/address"
	"github.com/moov-io/watchman/pkg/search"

	"github.com/gorilla/mux"
)

// GET /v2/search

type Controller interface {
	AppendRoutes(router *mux.Router) *mux.Router
}

func NewController(logger log.Logger, service Service) Controller {
	return &controller{
		logger:  logger,
		service: service,
	}
}

type controller struct {
	logger  log.Logger
	service Service
}

func (c *controller) AppendRoutes(router *mux.Router) *mux.Router {
	router.
		Name("Search.v2").
		Methods("GET").
		Path("/v2/search").
		HandlerFunc(c.search)

	return router
}

type searchResponse struct {
	Entities []SearchedEntity[search.Value] `json:"entities"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func (c *controller) search(w http.ResponseWriter, r *http.Request) {
	req, err := readSearchRequest(r)
	if err != nil {
		err = fmt.Errorf("problem reading v2 search request: %w", err)
		c.logger.Error().LogError(err)

		w.WriteHeader(http.StatusBadRequest)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(errorResponse{
			Error: err.Error(),
		})

		return
	}

	opts := SearchOpts{
		Limit:    extractSearchLimit(r),
		MinMatch: extractSearchMinMatch(r),
	}

	entities, err := c.service.Search(r.Context(), req, opts)
	if err != nil {
		c.logger.Error().LogErrorf("problem with v2 search: %v", err)

		w.WriteHeader(http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(searchResponse{
		Entities: entities,
	})
}

var (
	softResultsLimit, hardResultsLimit = 10, 100
)

func extractSearchLimit(r *http.Request) int {
	limit := softResultsLimit
	if v := r.URL.Query().Get("limit"); v != "" {
		n, _ := strconv.Atoi(v)
		if n > 0 {
			limit = n
		}
	}
	if limit > hardResultsLimit {
		limit = hardResultsLimit
	}
	return limit
}

func extractSearchMinMatch(r *http.Request) float64 {
	if v := r.URL.Query().Get("minMatch"); v != "" {
		n, _ := strconv.ParseFloat(v, 64)
		return n
	}
	return 0.00
}

func readSearchRequest(r *http.Request) (search.Entity[search.Value], error) {
	q := r.URL.Query()

	var err error
	var req search.Entity[search.Value]

	req.Name = strings.TrimSpace(q.Get("name"))
	req.Type = search.EntityType(strings.TrimSpace(strings.ToLower(q.Get("type"))))
	req.Source = search.SourceAPIRequest
	req.SourceID = strings.TrimSpace(q.Get("requestID"))

	switch req.Type {
	case search.EntityPerson:
		req.Person = &search.Person{
			Name:      req.Name,
			AltNames:  q["altNames"],
			Gender:    search.Gender(strings.TrimSpace(q.Get("gender"))),
			BirthDate: readDate(q.Get("birthDate")),
			DeathDate: readDate(q.Get("deathDate")),
			Titles:    q["titles"],
			// GovernmentIDs []GovernmentID `json:"governmentIDs"`
		}

	case search.EntityBusiness:
		req.Business = &search.Business{
			Name:      req.Name,
			Created:   readDate(q.Get("created")),
			Dissolved: readDate(q.Get("dissolved")),
			// Identifier []Identifier `json:"identifier"`
		}

	case search.EntityOrganization:
		req.Organization = &search.Organization{
			Name:      req.Name,
			Created:   readDate(q.Get("created")),
			Dissolved: readDate(q.Get("dissolved")),
			// Identifier []Identifier `json:"identifier"`
		}

	case search.EntityAircraft:
		req.Aircraft = &search.Aircraft{
			Name:         req.Name,
			Type:         search.AircraftType(q.Get("aircraftType")),
			Flag:         q.Get("flag"),
			Built:        readDate("built"),
			ICAOCode:     q.Get("icaoCode"),
			Model:        q.Get("model"),
			SerialNumber: q.Get("serialNumber"),
		}

	case search.EntityVessel:
		req.Vessel = &search.Vessel{
			Name:      req.Name,
			IMONumber: q.Get("imoNumber"),
			Type:      search.VesselType(q.Get("vesselType")),
			Flag:      q.Get("flag"),
			Built:     readDate("built"),
			Model:     q.Get("model"),
			MMSI:      q.Get("mmsi"),
			CallSign:  q.Get("callSign"),
			Owner:     q.Get("owner"),
		}
		req.Vessel.Tonnage, err = readInt(q.Get("tonnage"))
		if err != nil {
			return req, fmt.Errorf("reading vessel tonnage: %w", err)
		}
		req.Vessel.GrossRegisteredTonnage, err = readInt(q.Get("grossRegisteredTonnage"))
		if err != nil {
			return req, fmt.Errorf("reading vessel GrossRegisteredTonnage: %w", err)
		}
	}

	req.CryptoAddresses = readCryptoCurrencyAddresses(q["cryptoAddress"])
	req.Addresses = readAddresses(q["address"])

	// TODO(adam):
	// Affiliations   []Affiliation    `json:"affiliations"`
	// SanctionsInfo  *SanctionsInfo   `json:"sanctionsInfo"`
	// HistoricalInfo []HistoricalInfo `json:"historicalInfo"`

	return req, nil
}

var (
	allowedDateFormats = []string{"2006-01-02", "2006-01", "2006"}
)

func readDate(input string) *time.Time {
	if input == "" {
		return nil
	}

	for _, format := range allowedDateFormats {
		tt, err := time.Parse(format, input)
		if err == nil {
			return &tt
		}
	}
	return nil
}

func readInt(input string) (int, error) {
	n, err := strconv.ParseInt(input, 10, 32)
	return int(n), err
}

func readCryptoCurrencyAddresses(inputs []string) []search.CryptoAddress {
	var out []search.CryptoAddress
	for _, input := range inputs {
		// Query param looks like: cryptoAddress=XBT:x123456
		parts := strings.Split(input, ":")
		if len(parts) == 2 {
			out = append(out, search.CryptoAddress{
				Currency: parts[0],
				Address:  parts[1],
			})
		}
	}
	return out
}

func readAddresses(inputs []string) []search.Address {
	var out []search.Address
	for _, input := range inputs {
		out = append(out, address.ParseAddress(input))
	}
	return out
}
