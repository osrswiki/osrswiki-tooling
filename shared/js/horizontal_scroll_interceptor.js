(function() {
    'use strict';

    // This script helps prevent the native Android swipe gestures (like back navigation)
    // from firing when the user is trying to scroll a horizontally-scrollable
    // element within the WebView, such as a wide table.

    let isHorizontallyScrollable = false;
    let geChartTouchActive = false;
    let scrollAffordanceRefreshScheduled = false;
    const scrollSurfaceMarker = 'osrsScrollAffordanceBound';
    const scrollAffordanceClass = 'osrs-scroll-affordance';
    const scrollCanLeftClass = 'osrs-scroll-can-left';
    const scrollCanRightClass = 'osrs-scroll-can-right';
    const tableSelector = [
        'table.wikitable',
        'table.sortable',
        'table.filterable',
        'table.item-drops',
        'table.infobox-bonuses',
        'table.navbox',
        'table.questdetails',
        'table.calculator',
        'table[class*="combat"]',
        'table[class*="skill"]',
        'table[class*="training"]',
        'table[class*="league"]',
        'table[class*="task"]'
    ].join(',');
    const standaloneScrollSurfaceSelector = [
        '.mw-parser-output > table.wikitable',
        '.mw-parser-output > .wikitable',
        '.mw-parser-output > table.sortable',
        '.mw-parser-output > table.filterable',
        '.mw-parser-output > table.item-drops',
        '.mw-parser-output > table.navbox',
        '.mwe-math-element',
        'math.mwe-math-element'
    ].join(',');
    
    // Helper function to log to Android
    function log(message) {
        if (window.OsrsWikiBridge && typeof window.OsrsWikiBridge.log === 'function') {
            window.OsrsWikiBridge.log('[HorizontalScroll] ' + message);
        }
    }

    /**
     * Recursively checks if an element or any of its parents can scroll horizontally.
     * @param {HTMLElement} element The element to start checking from.
     * @returns {boolean} True if a horizontally scrollable element is found.
     */
    function checkHorizontalScroll(element) {
        if (!element || typeof element.scrollWidth === 'undefined' || typeof element.clientWidth === 'undefined') {
            return false;
        }
        
        // Check if element is within YouTube embed or other media that should not block gestures
        if (isMediaElement(element)) {
            log('Skipping media element: ' + element.tagName + ' ' + (element.className || ''));
            return false;
        }
        
        // Skip main content containers that are only slightly wider due to layout
        // These shouldn't block horizontal gestures for navigation
        if (isMainContentContainer(element)) {
            log('Skipping main content container: ' + element.tagName + ' ' + (element.className || ''));
            return checkHorizontalScroll(element.parentElement);
        }
        
        // If the element's scrollable width is greater than its visible width,
        // it is horizontally scrollable.
        if (element.scrollWidth > element.clientWidth) {
            log('Found scrollable element: ' + element.tagName + ' ' + (element.className || '') + 
                ' scrollWidth: ' + element.scrollWidth + ' clientWidth: ' + element.clientWidth);
            return true;
        }
        // If not, continue checking up the DOM tree.
        return checkHorizontalScroll(element.parentElement);
    }

    function getScrollSurfaceForTable(table) {
        if (!table || !table.closest) {
            return null;
        }
        return table.closest('.collapsible-content') ||
            table.closest('.collapsible-container') ||
            table.closest('.mw-parser-output > table.wikitable, .mw-parser-output > .wikitable') ||
            table;
    }

    function collectScrollSurfaces() {
        const surfaces = new Set();
        document.querySelectorAll(tableSelector).forEach(function(table) {
            const surface = getScrollSurfaceForTable(table);
            if (surface) {
                surfaces.add(surface);
            }
        });
        document.querySelectorAll(standaloneScrollSurfaceSelector).forEach(function(surface) {
            surfaces.add(surface);
        });
        return Array.from(surfaces).filter(function(surface) {
            return surface &&
                typeof surface.scrollWidth !== 'undefined' &&
                typeof surface.clientWidth !== 'undefined' &&
                !isMainContentContainer(surface) &&
                !isMediaElement(surface);
        });
    }

    function updateScrollSurfaceState(surface) {
        const overflowX = Math.max(0, surface.scrollWidth - surface.clientWidth);
        const rect = surface.getBoundingClientRect();
        const isScrollable = surface.clientWidth > 0 && rect.height > 0 && overflowX > 2;
        surface.classList.toggle(scrollAffordanceClass, isScrollable);
        surface.classList.toggle(scrollCanLeftClass, isScrollable && surface.scrollLeft > 2);
        surface.classList.toggle(scrollCanRightClass, isScrollable && surface.scrollLeft < overflowX - 2);

        if (isScrollable) {
            surface.dataset.osrsLocalOverflowX = String(Math.round(overflowX));
            if (surface.dataset[scrollSurfaceMarker] !== 'true') {
                surface.addEventListener('scroll', function() {
                    updateScrollSurfaceState(surface);
                }, { passive: true });
                surface.dataset[scrollSurfaceMarker] = 'true';
            }
        } else {
            delete surface.dataset.osrsLocalOverflowX;
        }
    }

    function refreshHorizontalScrollAffordances() {
        scrollAffordanceRefreshScheduled = false;
        collectScrollSurfaces().forEach(updateScrollSurfaceState);
    }

    function scheduleScrollAffordanceRefresh() {
        if (scrollAffordanceRefreshScheduled) {
            return;
        }
        scrollAffordanceRefreshScheduled = true;
        const schedule = window.requestAnimationFrame || window.setTimeout;
        schedule(refreshHorizontalScrollAffordances, 16);
    }

    function describeTable(table) {
        const rect = table.getBoundingClientRect();
        const surface = getScrollSurfaceForTable(table) || table;
        const surfaceRect = surface.getBoundingClientRect();
        const isVisibleSurface = surface.clientWidth > 0 && surfaceRect.height > 0;
        return {
            className: String(table.className || '').slice(0, 160),
            caption: (table.querySelector('caption') ? table.querySelector('caption').textContent : '').trim().replace(/\s+/g, ' ').slice(0, 120),
            width: Math.round(rect.width),
            localOverflowX: isVisibleSurface ? Math.round(Math.max(0, surface.scrollWidth - surface.clientWidth)) : 0,
            hasAffordance: !!(surface.classList && surface.classList.contains(scrollAffordanceClass))
        };
    }

    function collectArticleMetrics() {
        refreshHorizontalScrollAffordances();
        const viewportWidth = window.innerWidth;
        const root = document.scrollingElement || document.documentElement;
        const rootOverflowX = Math.max(0, root.scrollWidth - viewportWidth);
        const tables = Array.from(document.querySelectorAll(tableSelector));
        const localTableOverflows = tables
            .map(describeTable)
            .filter(function(item) {
                return item.localOverflowX > 2;
            });
        return {
            rootOverflowX: Math.round(rootOverflowX),
            localTableOverflowCount: localTableOverflows.length,
            maxLocalTableOverflowX: Math.max(0, ...localTableOverflows.map(function(item) { return item.localOverflowX; })),
            tableAffordanceCount: document.querySelectorAll('.' + scrollAffordanceClass).length,
            tableAffordanceCanRightCount: document.querySelectorAll('.' + scrollAffordanceClass + '.' + scrollCanRightClass).length,
            tableAffordanceCanLeftCount: document.querySelectorAll('.' + scrollAffordanceClass + '.' + scrollCanLeftClass).length,
            localTableOverflows: localTableOverflows.slice(0, 20)
        };
    }

    window.refreshHorizontalScrollAffordances = refreshHorizontalScrollAffordances;
    window.OSRSArticleMetrics = {
        collect: collectArticleMetrics,
        refreshHorizontalScrollAffordances: refreshHorizontalScrollAffordances
    };

    /**
     * Checks if an element is a main content container that shouldn't block gestures.
     * These are typically layout containers that are slightly wider than viewport.
     * @param {HTMLElement} element The element to check.
     * @returns {boolean} True if element is a main content container.
     */
    function isMainContentContainer(element) {
        const className = (element.className || '').toString().toLowerCase();
        const id = (element.id || '').toLowerCase();
        const tagName = element.tagName ? element.tagName.toLowerCase() : '';
        
        // Skip the body element - it shouldn't block navigation gestures
        if (tagName === 'body') {
            log('Found body element - skipping to allow navigation');
            return true;
        }
        
        // Check for MediaWiki main content containers
        if (className.includes('mw-content-ltr') && className.includes('mw-parser-output')) {
            log('Found main parser output container');
            return true;
        }
        
        // Check for section containers that are wide due to embedded content
        if (tagName === 'section' && (className.includes('collapsible-block') || className.includes('mf-section'))) {
            log('Found section container - likely wide due to embedded content');
            return true;
        }
        
        // Check for other common main content containers
        if (className.includes('main-content') || 
            className.includes('content-wrapper') ||
            className.includes('page-content') ||
            id.includes('content') ||
            id.includes('main')) {
            log('Found main content container by class/id');
            return true;
        }
        
        return false;
    }

    /**
     * Checks if an element is within a media container that should not block gestures.
     * @param {HTMLElement} element The element to check.
     * @returns {boolean} True if element is within excluded media.
     */
    function isMediaElement(element) {
        let current = element;
        let depth = 0;
        
        while (current && current !== document.body && depth < 10) {
            depth++;
            
            // Enhanced YouTube detection
            if (current.tagName === 'IFRAME') {
                const src = current.src || '';
                if (src.includes('youtube') || src.includes('youtu.be')) {
                    log('Found YouTube iframe: ' + src);
                    return true;
                }
            }
            
            // Check if we're inside a YouTube iframe's document
            if (window.location.href.includes('youtube')) {
                log('Inside YouTube iframe document');
                return true;
            }
            
            // Check for video elements
            if (current.tagName === 'VIDEO') {
                log('Found video element');
                return true;
            }
            
            // Check IDs and classes
            const id = (current.id || '').toLowerCase();
            const className = (current.className || '').toString().toLowerCase();
            
            if (id.includes('youtube') || id.includes('player') || id.includes('video')) {
                log('Found media by ID: ' + id);
                return true;
            }
            
            if (className.includes('youtube') || 
                className.includes('video') || 
                className.includes('player') || 
                className.includes('embed') ||
                className.includes('media')) {
                log('Found media by class: ' + className);
                return true;
            }
            
            current = current.parentElement;
        }
        return false;
    }

    /**
     * Touch start event listener.
     * Checks if the touch is on a scrollable element and notifies the native app.
     */
    function isInGEChart(target) {
        return !!(target && target.closest && (target.closest('.GEdatachart') || target.closest('.GEChartBox')));
    }

    document.addEventListener('touchstart', function(event) {
        const target = event.target;
        // Force-disable app back swipe for GE chart interactions
        if (isInGEChart(target)) {
            geChartTouchActive = true;
            if (window.OsrsWikiBridge && typeof window.OsrsWikiBridge.setHorizontalScroll === 'function') {
                window.OsrsWikiBridge.setHorizontalScroll(true);
                log('GE chart touchstart: setHorizontalScroll(true)');
            }
            return; // don't run generic check to avoid flipping state
        }
        log('Touch on: ' + target.tagName + ' ' + (target.className || '') + 
            ' at (' + Math.round(event.touches[0].clientX) + ', ' + Math.round(event.touches[0].clientY) + ')');
        
        // Check if the touch target is inside a scrollable container.
        isHorizontallyScrollable = checkHorizontalScroll(target);
        log('Scrollable: ' + isHorizontallyScrollable);
        
        if (window.OsrsWikiBridge && typeof window.OsrsWikiBridge.setHorizontalScroll === 'function') {
            // Inform the native layer whether a horizontal scroll is in progress.
            window.OsrsWikiBridge.setHorizontalScroll(isHorizontallyScrollable);
            log('Notified native layer: ' + isHorizontallyScrollable);
        }
    }, { passive: true });

    /**
     * Resets the scroll state when the touch gesture ends.
     */
    function resetScrollState() {
        if (geChartTouchActive) {
            geChartTouchActive = false;
            log('GE chart touchend: setHorizontalScroll(false)');
            if (window.OsrsWikiBridge && typeof window.OsrsWikiBridge.setHorizontalScroll === 'function') {
                window.OsrsWikiBridge.setHorizontalScroll(false);
            }
            isHorizontallyScrollable = false;
            return;
        }
        // Only send a reset call if the state was previously true, to avoid unnecessary calls.
        if (isHorizontallyScrollable) {
            log('Resetting scroll state to false');
            if (window.OsrsWikiBridge && typeof window.OsrsWikiBridge.setHorizontalScroll === 'function') {
                window.OsrsWikiBridge.setHorizontalScroll(false);
            }
            isHorizontallyScrollable = false;
        }
    }

    // Add listeners to reset the state when the touch gesture ends for any reason.
    document.addEventListener('touchend', resetScrollState, { passive: true });
    document.addEventListener('touchcancel', resetScrollState, { passive: true });
    document.addEventListener('DOMContentLoaded', scheduleScrollAffordanceRefresh, { once: true });
    window.addEventListener('load', scheduleScrollAffordanceRefresh, { once: true });
    window.addEventListener('resize', scheduleScrollAffordanceRefresh, { passive: true });

})();
