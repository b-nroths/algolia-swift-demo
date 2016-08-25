//
//  Copyright (c) 2016 Algolia
//  http://www.algolia.com/
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import AlgoliaSearch
import AlgoliaSearchHelper
import TTRangeSlider
import UIKit


class MoviesIpadViewController: UIViewController, UICollectionViewDataSource, TTRangeSliderDelegate, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate, SearchProgressDelegate {
    @IBOutlet weak var searchBar: UISearchBar!
    @IBOutlet weak var genreTableView: UITableView!
    @IBOutlet weak var yearRangeSlider: TTRangeSlider!
    @IBOutlet weak var ratingSelectorView: RatingSelectorView!
    @IBOutlet weak var moviesCollectionView: UICollectionView!
    @IBOutlet weak var moviesCollectionViewPlaceholder: UILabel!
    @IBOutlet weak var actorsTableView: UITableView!
    @IBOutlet weak var movieCountLabel: UILabel!
    @IBOutlet weak var searchTimeLabel: UILabel!
    @IBOutlet weak var genreTableViewFooter: UILabel!
    @IBOutlet weak var genreFilteringModeSwitch: UISwitch!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!

    var actorSearcher: Searcher!
    var movieSearcher: Searcher!
    var strategist: SearchStrategist!
    var actorHits: [[String: AnyObject]] = []
    var movieHits: [[String: AnyObject]] = []
    var genreFacets: [FacetValue] = []

    var yearFilterDebouncer = Debouncer(delay: 0.3)
    var progressController: SearchProgressController!

    override func viewDidLoad() {
        super.viewDidLoad()

        self.movieCountLabel.text = NSLocalizedString("movie_count_placeholder", comment: "")
        self.searchTimeLabel.text = nil

        // Customize search bar.
        searchBar.placeholder = NSLocalizedString("search_bar_placeholder", comment: "")
        searchBar.enablesReturnKeyAutomatically = false

        // Customize year range slider.
        yearRangeSlider.numberFormatterOverride = NSNumberFormatter()
        let tintColor = self.view.tintColor
        yearRangeSlider.tintColorBetweenHandles = tintColor
        yearRangeSlider.handleColor = tintColor
        yearRangeSlider.lineHeight = 3
        yearRangeSlider.minLabelFont = UIFont.systemFontOfSize(12)
        yearRangeSlider.maxLabelFont = yearRangeSlider.minLabelFont

        ratingSelectorView.addObserver(self, forKeyPath: "rating", options: .New, context: nil)

        // Customize genre table view.
        genreTableView.tableFooterView = genreTableViewFooter
        genreTableViewFooter.hidden = true

        // Configure actor search.
        actorSearcher = Searcher(index: AlgoliaManager.sharedInstance.actorsIndex, resultHandler: self.handleActorSearchResults)
        actorSearcher.query.hitsPerPage = 10
        actorSearcher.query.attributesToHighlight = ["name"]

        // Configure movie search.
        movieSearcher = Searcher(index: AlgoliaManager.sharedInstance.moviesIndex, resultHandler: self.handleMovieSearchResults)
        movieSearcher.query.facets = ["genre"]
        movieSearcher.query.attributesToHighlight = ["title"]
        movieSearcher.query.hitsPerPage = 30

        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(self.updatePlaceholder), name: Searcher.SearchNotification, object: movieSearcher)

        // Track progress to update activity indicator.
        progressController = SearchProgressController(searcher: movieSearcher)
        progressController.delegate = self
        progressController.graceDelay = 0.5

        strategist = SearchStrategist()
        strategist.addSearcher(movieSearcher)
        strategist.addSearcher(actorSearcher)
        strategist.addObserver(self, forKeyPath: "strategy", options: .New, context: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(self.requestDropped), name: SearchStrategist.DropNotification, object: strategist)
        
        updateMovies()
        search()

        // Start a sync if needed.
        AlgoliaManager.sharedInstance.syncIfNeededAndPossible()
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    // MARK: - State update
    
    private func updateMovies() {
        moviesCollectionViewPlaceholder.hidden = !movieHits.isEmpty
        if movieHits.isEmpty {
            moviesCollectionViewPlaceholder.text = "No results"
        }
        moviesCollectionView.reloadData()
    }
    
    private func updateStatusLabelColor() {
        switch strategist.strategy {
        case .Realtime: searchTimeLabel.textColor = UIColor.greenColor(); break
        case .Throttled: searchTimeLabel.textColor = UIColor.purpleColor(); break
        case .Manual: searchTimeLabel.textColor = UIColor.orangeColor(); break
        }
    }

    // MARK: - Actions

    private func search(asYouType: Bool = false) {
        movieSearcher.disjunctiveFacets = genreFilteringModeSwitch.on ? ["genre"] : []
        movieSearcher.query.numericFilters = [
            "year >= \(Int(yearRangeSlider.selectedMinimum))",
            "year <= \(Int(yearRangeSlider.selectedMaximum))",
            "rating >= \(ratingSelectorView.rating)"
        ]
        strategist.search(asYouType)
    }

    @IBAction func genreFilteringModeDidChange(sender: AnyObject) {
        movieSearcher.setFacet("genre", disjunctive: genreFilteringModeSwitch.on)
        search()
    }

    @IBAction func configTapped(sender: AnyObject) {
        let vc = ConfigViewController(nibName: "ConfigViewController", bundle: nil)
        self.presentViewController(vc, animated: true, completion: nil)
    }

    // MARK: - UISearchBarDelegate

    func searchBar(searchBar: UISearchBar, textDidChange searchText: String) {
        actorSearcher.query.query = searchText
        movieSearcher.query.query = searchText
        search(true)
    }
    
    func searchBarSearchButtonClicked(searchBar: UISearchBar) {
        search()
    }
    
    // MARK: - Search completion handlers

    private func handleActorSearchResults(results: SearchResults?, error: NSError?) {
        guard let results = results else { return }
        if results.page == 0 {
            actorHits = results.hits
        } else {
            actorHits.appendContentsOf(results.hits)
        }
        self.actorsTableView.reloadData()

        // Scroll to top.
        if results.page == 0 {
            self.moviesCollectionView.contentOffset = CGPointZero
        }
    }

    private func handleMovieSearchResults(results: SearchResults?, error: NSError?) {
        guard let results = results else {
            self.searchTimeLabel.textColor = UIColor.redColor()
            self.searchTimeLabel.text = NSLocalizedString("error_search", comment: "")
            return
        }
        if results.page == 0 {
            movieHits = results.hits
        } else {
            movieHits.appendContentsOf(results.hits)
        }
        // Sort facets: first selected facets, then by decreasing count, then by name.
        genreFacets = results.facets("genre")?.sort({ (lhs, rhs) in
            // When using cunjunctive faceting ("AND"), all refined facet values are displayed first.
            // But when using disjunctive faceting ("OR"), refined facet values are left where they are.
            let disjunctiveFaceting = results.disjunctiveFacets.contains("genre") ?? false
            let lhsChecked = self.movieSearcher.hasFacetRefinement("genre", value: lhs.value)
            let rhsChecked = self.movieSearcher.hasFacetRefinement("genre", value: rhs.value)
            if !disjunctiveFaceting && lhsChecked != rhsChecked {
                return lhsChecked
            } else if lhs.count != rhs.count {
                return lhs.count > rhs.count
            } else {
                return lhs.value < rhs.value
            }
        }) ?? []
        let exhaustiveFacetsCount = results.exhaustiveFacetsCount == true
        genreTableViewFooter.hidden = exhaustiveFacetsCount

        let formatter = NSNumberFormatter()
        formatter.locale = NSLocale.currentLocale()
        formatter.numberStyle = .DecimalStyle
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        self.movieCountLabel.text = "\(formatter.stringFromNumber(results.nbHits)!) MOVIES"

        updateStatusLabelColor()
        self.searchTimeLabel.text = "Found in \(results.processingTimeMS) ms"
        // Indicate origin of content.
        if results.content["origin"] as? String == "local" {
            searchTimeLabel.text! += " (offline results)"
        }

        self.genreTableView.reloadData()
        updateMovies()

        // Scroll to top.
        if results.page == 0 {
            self.moviesCollectionView.contentOffset = CGPointZero
        }
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return movieHits.count
    }

    func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCellWithReuseIdentifier("movieCell", forIndexPath: indexPath) as! MovieCell
        cell.movie = MovieRecord(json: movieHits[indexPath.item])
        if indexPath.item + 5 >= movieHits.count {
            movieSearcher.loadMore()
        }
        return cell
    }

    // MARK: - UITableViewDataSource

    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch tableView {
            case actorsTableView: return actorHits.count ?? 0
            case genreTableView: return genreFacets.count
            default: assert(false); return 0
        }
    }

    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        switch tableView {
            case actorsTableView:
                let cell = tableView.dequeueReusableCellWithIdentifier("actorCell", forIndexPath: indexPath) as! ActorCell
                cell.actor = Actor(json: actorHits[indexPath.item])
                if indexPath.item + 5 >= actorHits.count {
                    actorSearcher.loadMore()
                }
                return cell
            case genreTableView:
                let cell = tableView.dequeueReusableCellWithIdentifier("genreCell", forIndexPath: indexPath) as! GenreCell
                cell.value = genreFacets[indexPath.item]
                cell.checked = movieSearcher.hasFacetRefinement("genre", value: genreFacets[indexPath.item].value)
                return cell
            default: assert(false); return UITableViewCell()
        }
    }

    // MARK: - UITableViewDelegate

    func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        switch tableView {
            case genreTableView:
                movieSearcher.toggleFacetRefinement("genre", value: genreFacets[indexPath.item].value)
                strategist.search(false)
                break
            default: return
        }
    }

    // MARK: - TTRangeSliderDelegate

    func rangeSlider(sender: TTRangeSlider!, didChangeSelectedMinimumValue selectedMinimum: Float, andMaximumValue selectedMaximum: Float) {
        yearFilterDebouncer.call {
            self.search(false)
        }
    }

    // MARK: - KVO

    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        guard let object = object as? NSObject else { return }
        if object === ratingSelectorView {
            if keyPath == "rating" {
                search()
            }
        } else if object === strategist {
            if keyPath == "strategy" {
                guard let strategy = change?[NSKeyValueChangeNewKey] as? Int else { return }
                searchTimeLabel.text = "New strategy: \(strategy)"
                updateStatusLabelColor()
            }
        }
    }
    
    // MARK: - Activity indicator

    func searchDidStart(searchProgressController: SearchProgressController) {
        activityIndicator.startAnimating()
        UIApplication.sharedApplication().networkActivityIndicatorVisible = true
    }

    func searchDidStop(searchProgressController: SearchProgressController) {
        activityIndicator.stopAnimating()
        UIApplication.sharedApplication().networkActivityIndicatorVisible = false
    }

    // MARK: - Events
    
    @objc private func requestDropped(notification: NSNotification) {
        // Now that we have dropped a request, we should not display any results, as they won't correspond to the
        // last entered text. => Cancel all pending requests.
        movieSearcher.cancelPendingRequests()
        actorHits.removeAll()
        movieHits.removeAll()
        actorsTableView.reloadData()
        updateMovies()
        moviesCollectionViewPlaceholder.text = "Press “Search” to see results…"
    } ////
    
    @objc private func updatePlaceholder(notification: NSNotification) {
        if notification.name == Searcher.SearchNotification {
            moviesCollectionViewPlaceholder.text = "Searching…"
        }
    } ////
}
