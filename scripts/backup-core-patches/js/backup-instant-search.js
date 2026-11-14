/*
 * HestiaCP Backup Instant Search & Client-Side Pagination
 * Managed by hestiacp-useful-tools (scripts/backup-core-patches)
 *
 * Loaded automatically via /usr/local/hestia/web/js/custom_scripts/.
 * Enhances /list/backup/* views with 0ms client-side search filtering and
 * client-side pagination while preserving Hestia sorting and BulkEdit safety.
 */
(() => {
	'use strict';

	const DEFAULT_PAGE_SIZE = 25;
	const PAGE_SIZE_OPTIONS = [25, 50, 100, 0];

	function initBackupListEnhancements() {
		if (!window.location.pathname.startsWith('/list/backup/')) {
			return;
		}

		const unitsContainer = document.querySelector('.js-units-container');
		if (!unitsContainer) {
			return;
		}

		const isPt = /^pt\b/i.test((document.documentElement.lang || '').replace('_', '-'));
		const labels = {
			empty: isPt ? 'Nenhum resultado encontrado.' : 'No matching items found.',
			all: isPt ? 'Todos' : 'All',
			perPage: isPt ? 'Por página' : 'Per page',
			page: isPt ? 'Página' : 'Page',
			prev: isPt ? 'Página anterior' : 'Previous page',
			next: isPt ? 'Página seguinte' : 'Next page',
		};

		const searchInput = document.querySelector('.toolbar-search .js-search-input');
		const searchForm = searchInput ? searchInput.closest('form') : null;
		const toggleAllCheckbox = document.querySelector('.js-toggle-all-checkbox');
		const sortingMenu = document.querySelector('.js-sorting-menu');
		const footer =
			document.querySelector('.units-table-footer') ||
			document.querySelector('main footer.app-footer .app-footer-inner') ||
			document.querySelector('.app-footer-inner');
		const countEl = footer ? footer.querySelector('p') : null;

		const urlParams = new URLSearchParams(window.location.search);
		const initialServerQuery = (urlParams.get('q') || '').trim().toLowerCase();

		const searchableTextCache = new WeakMap();
		const getUnits = () => Array.from(unitsContainer.querySelectorAll('.js-unit'));

		const getSearchText = (unit) => {
			if (!searchableTextCache.has(unit)) {
				const raw = `${unit.textContent || ''} ${unit.getAttribute('data-sort-name') || ''}`;
				searchableTextCache.set(unit, raw.replace(/\s+/g, ' ').trim().toLowerCase());
			}
			return searchableTextCache.get(unit);
		};

		// Preserve server-rendered disabled states so visibility toggling never enables protected checkboxes.
		getUnits().forEach((unit) => {
			const cb = unit.querySelector('.js-unit-checkbox');
			if (cb && cb.dataset.serverDisabled === undefined) {
				cb.dataset.serverDisabled = cb.disabled ? '1' : '0';
			}
			getSearchText(unit);
		});

		const initialTotal = getUnits().length;
		const initialCountText = countEl ? countEl.textContent.trim() : '';
		const unitLabel = initialCountText.replace(/^\s*\d[\d\s.,]*\s*/, '').trim();

		let pageSize = DEFAULT_PAGE_SIZE;
		let currentPage = 1;

		// Empty-state row for zero search matches.
		const emptyStateRow = document.createElement('div');
		emptyStateRow.className = 'units-table-row js-empty-search-state';
		emptyStateRow.style.display = 'none';
		const emptyStateCell = document.createElement('div');
		emptyStateCell.className = 'units-table-cell u-text-center';
		emptyStateCell.style.gridColumn = '1 / -1';
		emptyStateCell.style.padding = '16px';
		emptyStateCell.textContent = labels.empty;
		emptyStateRow.appendChild(emptyStateCell);
		unitsContainer.appendChild(emptyStateRow);

		// Pagination controls inside footer.
		let pager = null;
		let sizeSelect = null;
		let prevBtn = null;
		let nextBtn = null;
		let pageInfo = null;

		if (footer) {
			footer.style.display = 'flex';
			footer.style.alignItems = 'center';
			footer.style.justifyContent = 'space-between';
			footer.style.flexWrap = 'wrap';
			footer.style.gap = '10px';

			pager = document.createElement('div');
			pager.className = 'js-backup-pagination';
			pager.style.display = 'none';
			pager.style.alignItems = 'center';
			pager.style.gap = '8px';

			sizeSelect = document.createElement('select');
			sizeSelect.className = 'form-select';
			sizeSelect.setAttribute('aria-label', labels.perPage);
			sizeSelect.title = labels.perPage;
			PAGE_SIZE_OPTIONS.forEach((size) => {
				const opt = document.createElement('option');
				opt.value = String(size);
				opt.textContent = size === 0 ? labels.all : String(size);
				if (size === pageSize) {
					opt.selected = true;
				}
				sizeSelect.appendChild(opt);
			});

			prevBtn = document.createElement('button');
			prevBtn.type = 'button';
			prevBtn.className = 'button button-secondary';
			prevBtn.setAttribute('aria-label', labels.prev);
			prevBtn.title = labels.prev;
			prevBtn.textContent = '‹';

			pageInfo = document.createElement('span');
			pageInfo.className = 'u-text-bold';

			nextBtn = document.createElement('button');
			nextBtn.type = 'button';
			nextBtn.className = 'button button-secondary';
			nextBtn.setAttribute('aria-label', labels.next);
			nextBtn.title = labels.next;
			nextBtn.textContent = '›';

			pager.appendChild(sizeSelect);
			pager.appendChild(prevBtn);
			pager.appendChild(pageInfo);
			pager.appendChild(nextBtn);
			footer.appendChild(pager);
		}

		const enforceHiddenCheckboxesDisabled = () => {
			getUnits().forEach((unit) => {
				const isHidden = unit.classList.contains('u-hidden') || unit.style.display === 'none';
				const cb = unit.querySelector('.js-unit-checkbox');
				if (!cb) {
					return;
				}
				if (isHidden) {
					cb.checked = false;
					cb.disabled = true;
					unit.classList.remove('selected');
				}
			});
		};

		const render = () => {
			const allUnits = getUnits();
			const query = searchInput ? searchInput.value.trim().toLowerCase() : '';
			const matched =
				query === '' ? allUnits : allUnits.filter((unit) => getSearchText(unit).includes(query));

			const effectiveSize = pageSize > 0 ? pageSize : Math.max(1, matched.length);
			const totalPages = pageSize > 0 ? Math.max(1, Math.ceil(matched.length / effectiveSize)) : 1;
			if (currentPage > totalPages) {
				currentPage = totalPages;
			}
			if (currentPage < 1) {
				currentPage = 1;
			}

			const visibleSlice =
				pageSize > 0
					? matched.slice((currentPage - 1) * pageSize, currentPage * pageSize)
					: matched;
			const visibleSet = new Set(visibleSlice);

			allUnits.forEach((unit) => {
				const cb = unit.querySelector('.js-unit-checkbox');
				if (visibleSet.has(unit)) {
					unit.classList.remove('u-hidden');
					unit.style.display = '';
					if (cb) {
						cb.disabled = cb.dataset.serverDisabled === '1';
					}
				} else {
					unit.classList.add('u-hidden');
					unit.style.display = 'none';
					unit.classList.remove('selected');
					if (cb) {
						cb.checked = false;
						cb.disabled = true;
					}
				}
			});

			// Keep empty state last inside the container even after listSorting.js appends units.
			unitsContainer.appendChild(emptyStateRow);
			emptyStateRow.style.display = allUnits.length > 0 && matched.length === 0 ? '' : 'none';

			if (toggleAllCheckbox) {
				const enabledVisible = visibleSlice
					.map((unit) => unit.querySelector('.js-unit-checkbox'))
					.filter((cb) => cb && !cb.disabled);
				toggleAllCheckbox.checked =
					enabledVisible.length > 0 && enabledVisible.every((cb) => cb.checked);
			}

			if (countEl) {
				if (query === '' && matched.length === initialTotal && initialCountText !== '') {
					countEl.textContent = initialCountText;
				} else {
					countEl.textContent = unitLabel
						? `${matched.length} / ${allUnits.length} ${unitLabel}`
						: `${matched.length} / ${allUnits.length}`;
				}
			}

			if (pager) {
				const shouldShowPager = allUnits.length > DEFAULT_PAGE_SIZE;
				pager.style.display = shouldShowPager ? 'inline-flex' : 'none';
				pageInfo.textContent = `${labels.page} ${currentPage} / ${totalPages}`;
				prevBtn.disabled = currentPage <= 1;
				nextBtn.disabled = currentPage >= totalPages;
			}
		};

		const handleSearchInput = () => {
			const query = searchInput ? searchInput.value.trim().toLowerCase() : '';
			// If PHP pre-filtered the initial HTML via ?q=..., clearing/shortening below that query reloads full data once.
			if (initialServerQuery !== '' && !query.includes(initialServerQuery)) {
				const nextUrl = new URL(window.location.href);
				nextUrl.searchParams.delete('q');
				window.location.assign(nextUrl.toString());
				return;
			}
			currentPage = 1;
			render();
		};

		if (searchInput) {
			searchInput.addEventListener('input', handleSearchInput);
			searchInput.addEventListener('search', handleSearchInput);
			searchInput.addEventListener('keydown', (evt) => {
				if (evt.key === 'Escape' && searchInput.value !== '') {
					evt.stopPropagation();
					searchInput.value = '';
					handleSearchInput();
				}
			});
		}

		if (searchForm) {
			searchForm.addEventListener('submit', (evt) => {
				evt.preventDefault();
				handleSearchInput();
			});
		}

		if (sizeSelect) {
			sizeSelect.addEventListener('change', () => {
				const parsed = Number.parseInt(sizeSelect.value, 10);
				pageSize = Number.isNaN(parsed) ? DEFAULT_PAGE_SIZE : parsed;
				currentPage = 1;
				render();
			});
		}

		if (prevBtn) {
			prevBtn.addEventListener('click', () => {
				if (currentPage > 1) {
					currentPage -= 1;
					render();
				}
			});
		}

		if (nextBtn) {
			nextBtn.addEventListener('click', () => {
				currentPage += 1;
				render();
			});
		}

		if (toggleAllCheckbox) {
			toggleAllCheckbox.addEventListener('change', enforceHiddenCheckboxesDisabled);
		}

		if (sortingMenu) {
			sortingMenu.addEventListener('click', () => {
				window.setTimeout(() => {
					currentPage = 1;
					render();
				}, 0);
			});
		}

		render();
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', initBackupListEnhancements);
	} else {
		initBackupListEnhancements();
	}
})();
